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
        guard let id = sent.device, let box = sent.box else { return .refused(401) }
        var device: PhoneDevice, ask: Ask, fresh = false
        do {
            if let known = devices[id] {
                device = known
                ask = try PhoneSeal.open(box, about: "q", key: known.key)
            } else {
                guard let pairing, pairing.until > Date(), id.wholeMatch(of: /[\w-]{16,32}/) != nil else {
                    return .refused(401)
                }
                ask = try PhoneSeal.open(box, about: "q", key: pairing.key)
                guard ask.path == "pair" else { return .refused(401) }
                let name = ask.body?["name"]?.string ?? "Phone"
                device = PhoneDevice(key: pairing.key, name: String(name.prefix(80)))
                fresh = true
            }
        } catch { return .refused(401) }
        guard device.admit(ask.n) else { return .refused(409) }
        devices[id] = device
        if fresh {
            pairing = nil   // a link pairs one phone only
            let key = device.key.withUnsafeBytes { Data($0).base64URL }
            guard
                Log.session.attempt("keeping a phone's key", { try Keychain.set(key, account: "phone.device.\(id)") })
                    != nil
            else {
                devices[id] = nil
                return .refused(401)
            }
        }
        if fresh || device.needsSaving { remember() }
        let number = Int64(ask.n), key = device.key
        let done = Self.sealed { try PhoneSeal.seal(Reply(status: 204), about: "r\(number)", key: key) }
        switch ask.path {
        case "pair":
            // The phone sends a key of its own to keep, because the link may stay in an address bar or on a
            // clipboard. The link's key seals this one answer and opens nothing after it.
            guard fresh, let mine = ask.body?["key"]?.string.flatMap(Data.init(base64URL:)), mine.count == 32,
                let rekeyed = Self.sealed({
                    try PhoneSeal.seal(
                        Reply(status: 200, body: .object(["rekeyed": .bool(true)])), about: "r\(number)", key: key)
                }),
                Log.session.attempt(
                    "keeping a phone's own key", { try Keychain.set(mine.base64URL, account: "phone.device.\(id)") })
                    != nil
            else { return done.map(Admitted.answer) ?? .refused(401) }
            devices[id]?.key = SymmetricKey(data: mine)
            return .answer(rekeyed)
        case "unpair":
            forget(id)
            return done.map(Admitted.answer) ?? .refused(401)
        case "events":
            return .events(Stream(device: id, key: device.key, number: number))
        default: return .ask(ask, device: id, key: device.key)
        }
    }

    /// Answers what is inside a call. Each path maps to one of the daemon's methods, which is called as the user
    /// (`Asker`).
    func answer(_ ask: Ask, from device: String) async -> Reply {
        let method = ask.method ?? "GET", path = ask.path ?? "", sent = ask.body
        switch (method, path) {
        case ("GET", "agents"):
            shown = sessions().filter(PhoneAgent.shown).reduce(into: [:]) { $0[$1.id] = agent($1) }
            let agents = shown.values.sorted { ($0["statusAt"]?.string ?? "") > ($1["statusAt"]?.string ?? "") }
            var body: [String: JSONValue] = [
                "mac": .string(Self.macName), "agents": .array(agents.map(JSONValue.object)),
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
            devices[device]?.push = subscription
            remember()
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
                guard let answer = sent?["answer"]?.string, ["allow", "deny"].contains(answer) else {
                    return Reply(status: 200, body: .object(["ok": .bool(false)]))
                }
                let chose = SessionChoose(id: id, answer: answer, question: sent?["question"]?.string)
                return Reply(status: 200, body: .object(["ok": .bool(try await call(chose))]))
            case "reply":
                guard let text = sent?["text"]?.string else { return .failed(400, "Send {\"text\"}.") }
                _ = try await call(SessionSend(id: id, text: text))
                return Reply(status: 204)
            default:
                var agent = agent(session)
                // Limit: only the last 200,000 characters of a longer reply go out, because the relay passes a
                // megabyte at most.
                let reply = try await call(SessionLastReply(id: id)).map { String($0.suffix(200_000)) }
                agent["lastReply"] = reply.map(JSONValue.string) ?? .null
                if let turns = await turns(of: session) { agent["turns"] = .array(turns) }
                return Reply(status: 200, body: .object(agent))
            }
        } catch {
            return .failed(403, error.rpcMessage)   // The Mac refused, and the phone shows the Mac's message.
        }
    }
}
