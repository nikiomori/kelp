import Core
import CryptoKit
import Foundation
import SystemConfiguration
import os

// MARK: - A call

extension PhoneBridge {
    /// The request that a phone sealed. `n` numbers the phone's own requests, and no number is used twice.
    struct Ask: Codable {
        var n: Double, method: String?, path: String?, body: JSONValue?
    }
    struct Reply: Codable, Equatable {
        var status: Int
        var body: JSONValue?
        static func failed(_ status: Int, _ error: String) -> Reply {
            Reply(status: status, body: .object(["error": .string(error)]))
        }
        /// A call that failed: 403 when the Mac refused it, 400 when it was asked wrong, 500 when something on the Mac
        /// went wrong. The phone shows the Mac's message either way.
        static func failed(_ error: Error) -> Reply {
            let rpc = error as? RPCError
            let status = rpc?.isRefusal == true ? 403 : rpc?.code == RPCError.invalidParams("").code ? 400 : 500
            return failed(status, error.rpcMessage)
        }
    }
    enum Admitted {
        /// The call is refused unopened, with 401 for a phone that is not paired or a box that doesn't open, and 409
        /// for a request number seen before.
        case refused(Int)
        case answer(String)
        case events(Stream)
        case ask(Ask, device: String, key: SymmetricKey)
    }

    /// Checks a call's envelope: which phone sent it, that its box opens, and that it is new. It then handles pairing,
    /// unpairing and event streams, which need no agent, and passes any other call on as an `ask`.
    func admit(_ sent: Sent) -> Admitted {
        guard way != nil else { return .refused(503) }
        guard let id = sent.device, let box = sent.box else { return .refused(401) }
        var device: PhoneDevice
        let ask: Ask
        do {
            guard let known = devices[id] else { return try register(id, box: box) }
            device = known
            ask = try PhoneSeal.open(box, about: "q", key: device.key)
        } catch { return .refused(401) }
        guard device.admit(ask.n) else { return .refused(409) }
        if device.needsSaving {
            guard Log.session.attempt("keeping a phone's request number", { try save(device, id: id) }) != nil
            else { return .refused(503) }
        } else {
            devices[id] = device
        }
        let number = Int64(ask.n)
        switch (ask.method ?? "GET", ask.path) {
        case (_, "pair"): return .refused(401)
        case ("POST", "unpair"):
            guard
                let done = Self.sealed({ try PhoneSeal.seal(Reply(status: 204), about: "r\(number)", key: device.key) })
            else { return .refused(500) }
            guard Log.session.attempt("forgetting a phone", { try forget(id) }) != nil else { return .refused(503) }
            return .answer(done)
        case ("GET", "events"):
            return .events(Stream(device: id, key: device.key, number: number))
        default: return .ask(ask, device: id, key: device.key)
        }
    }

    private func register(_ id: String, box: String) throws -> Admitted {
        guard record?.devices[id] == nil, let pairing, pairing.until > Date(), id.wholeMatch(of: /[\w-]{16,32}/) != nil
        else { return .refused(401) }
        let ask: Ask = try PhoneSeal.open(box, about: "q", key: pairing.key)
        guard ask.method == "POST", ask.path == "pair",
            let mine = ask.body?["key"]?.string.flatMap(Data.init(base64URL:)), mine.count == 32,
            SymmetricKey(data: mine) != pairing.key
        else { return .refused(401) }
        let name = ask.body?["name"]?.string ?? "Phone"
        var device = PhoneDevice(key: SymmetricKey(data: mine), name: String(name.prefix(80)))
        guard device.admit(ask.n) else { return .refused(409) }
        let reply = Reply(status: 200, body: .object(["rekeyed": .bool(true)]))
        guard let answer = Self.sealed({ try PhoneSeal.seal(reply, about: "r\(Int64(ask.n))", key: pairing.key) })
        else { return .refused(500) }

        let account = "phone.device.\(id)"
        guard
            Log.session.attempt("keeping a phone's key", { try Keychain.set(mine.base64URL, account: account) }) != nil
        else { return .refused(503) }
        guard Log.session.attempt("keeping a paired phone", { try save(device, id: id) }) != nil else {
            Keychain.delete(account)
            return .refused(503)
        }
        self.pairing = nil
        return .answer(answer)
    }

    /// Answers what is inside a call. Each path maps to one of the daemon's methods, which is called as the user
    /// (`Asker`).
    func answer(_ ask: Ask, from device: String) async -> Reply {
        let method = ask.method ?? "GET", path = ask.path ?? "", sent = ask.body
        switch (method, path) {
        case ("GET", "agents"):
            refreshAgents()
            let agents = shown.values.sorted {
                ($0["statusAt"]?.string ?? "") > ($1["statusAt"]?.string ?? "")
            }
            var body: [String: JSONValue] = [
                "mac": .string(Self.macName), "agents": .array(agents.map(JSONValue.object)),
                "revision": .int(agentRevision),
                "stops": .bool(true)   // This Mac answers `agents/<id>/stop`, so the page shows Stop.
            ]
            // The version of the page that Kelp serves now. A phone that runs an older page (because Kelp updated
            // while the page stayed open) reloads.
            if server != nil, let page = PhoneHTTP.pageVersion { body["page"] = .string(page) }
            body.merge(await projectsAndKinds()) { _, new in new }
            return Reply(status: 200, body: .object(body))
        case ("GET", "push/key"):
            guard let key = vapid() else { return .failed(503, "The Mac's keychain is locked.") }
            return Reply(status: 200, body: .object(["key": .string(key.publicKey.x963Representation.base64URL)]))
        case ("POST", "push/subscribe"), ("DELETE", "push/subscribe"):
            let subscription = method == "POST" ? PushSubscription(sent) : nil
            if method == "POST", subscription == nil { return .failed(400, "Not a push subscription.") }
            guard var phone = devices[device] else { return .failed(401, "Phone is no longer paired.") }
            phone.push = subscription
            do { try save(phone, id: device) } catch { return .failed(503, "Couldn't save this notification setting.") }
            return Reply(status: 204)
        default: break
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == "projects", let project = parts[1].removingPercentEncoding {
            return await answer(method, project: project, parts[2], sent)
        }
        guard parts.count == 2 || parts.count == 3, parts[0] == "agents", let id = parts[1].removingPercentEncoding,
            parts.count == 2
                ? method == "GET" : method == "POST" && ["choose", "reply", "read", "stop"].contains(parts[2])
        else { return .failed(404, "No such path.") }
        guard let session = session(id), PhoneAgent.shown(session) else { return .failed(404, "This agent is gone.") }
        guard asker != nil else { return .failed(503, "The Mac is not answering.") }
        do {
            switch parts.count == 3 ? parts[2] : "" {
            case "read":
                _ = try await call(SessionMarkRead(id: id))
                return Reply(status: 204)
            case "stop":
                // Sends Esc, as if the user pressed it in the agent's terminal. The agent stops what it is doing and
                // waits, and the session doesn't end.
                _ = try await call(SessionWrite(id: id, text: "\u{1B}"))
                return Reply(status: 204)
            case "choose":
                guard let answer = sent?["answer"]?.string, ["allow", "deny"].contains(answer),
                    let question = sent?["question"]?.string, !question.isEmpty,
                    let questionId = sent?["questionId"]?.string, UUID(uuidString: questionId) != nil
                else {
                    return Reply(status: 200, body: .object(["ok": .bool(false)]))
                }
                let chose = SessionChoose(id: id, answer: answer, question: question, questionId: questionId)
                return Reply(status: 200, body: .object(["ok": .bool(try await call(chose))]))
            case "reply":
                guard let text = sent?["text"]?.string else { return .failed(400, "Send {\"text\"}.") }
                _ = try await call(SessionSend(id: id, text: text))
                return Reply(status: 204)
            default:
                var agent = agent(session)
                agent.merge(await conversationFields(of: session, seen: sent?["seen"]?.string)) { _, value in value }
                return Reply(status: 200, body: .object(agent))
            }
        } catch {
            return .failed(403, error.rpcMessage)   // The Mac refused, and the phone shows the Mac's message.
        }
    }
}
