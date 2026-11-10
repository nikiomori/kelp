import Agents
import Core
import Foundation
import os

// The socket's side of the daemon: each connection's reader, how a request is answered and its reply goes out, and a
// terminal's raw stream (`session.stream`).

extension Daemon {
    /// A request as it comes: JSON-RPC lets the id be a string too, and the reply carries it back as it came.
    struct Request: Decodable {
        let id: JSONValue?
        let method: String
        let params: JSONValue?
        var isNotification: Bool { id == nil || id == .null }
    }
    struct Reply: Encodable {
        var jsonrpc = "2.0"
        let id: JSONValue
        let error: RPCError
    }

    func serve(_ fd: Int32) {
        let client = clients.add(fd: fd)
        // Accepted as this one stopped or handed over (its cancel doesn't stop an accept already running): added first,
        // then looked at, so either the stop's hang-up has it or it's hung up here (its reader then reads the end and
        // cleans up as for any other), and connects to the next one.
        if !isServing { client.hangUp() }
        Thread.detachNewThread { [self] in
            // Who it is, looked up before anything it sent is read, while its program is surely there: here, not on the
            // accept queue, as a tmux pane's asks tmux (`Callers.tmuxPane`).
            _ = sessions.callers.caller(client.id)
            var received = LineBuffer()
            var buf = [UInt8](repeating: 0, count: 65536)
            var spoke = false
            // Requests of this client still being answered: past `pendingLimit` more are refused, not queued for good.
            let pending = OSAllocatedUnfairLock(initialState: 0)
            var ended = false   // the client said all it had (`printf … | nc -U`): what it asked is still answered
            reading: while true {
                let count = read(fd, &buf, buf.count)
                if count <= 0 {
                    ended = count == 0
                    break
                }
                let lines = received.append(Data(buf[0..<count]))
                // A line past any request's size (a 50 MB file saved, escaped) isn't one: hang up rather than keep it all.
                guard received.pending <= Self.lineLimit else {
                    Log.rpc.error("hung up on a client whose line passed \(Self.lineLimit) bytes with no end")
                    break reading
                }
                for (index, line) in lines.enumerated() {
                    guard let req = try? JSONDecoder().decode(Request.self, from: line) else {
                        refuse(line, client)
                        continue
                    }
                    // A JSON-RPC client after all (it came in raw, Clients.add): events from now on.
                    if !spoke {
                        spoke = true
                        if req.method != SessionStream.name { clients.setRaw(client.id, false) }
                    }
                    if let handler = Self.methods[req.method] as? any Handled.Type, handler.inOrder {
                        answerInOrder(handler, req, client)
                        continue
                    }
                    // Not a call: it ends JSON-RPC on this connection, which becomes a raw byte pipe (kelp attach).
                    if req.method == SessionStream.name {
                        // What came after its line in the same read is the stream's already: its whole lines, then the rest.
                        let after = lines[(index + 1)...].reduce(Data()) { $0 + $1 + Data("\n".utf8) }
                        stream(client, req.params ?? .null, leftover: after + received.takeRemainder())
                        break reading
                    }
                    let admitted = pending.withLock { n -> Bool in
                        guard n < Self.pendingLimit else { return false }
                        n += 1
                        return true
                    }
                    guard admitted else {
                        let refusal = Self.errorLine(
                            id: req.id ?? .null, RPCError.internalError("Too many requests at once."))
                        if !req.isNotification, let refusal { client.send(refusal) }
                        continue
                    }
                    Task {
                        await self.respond(req, conn: client)
                        pending.withLock { $0 -= 1 }
                    }
                }
            }
            // Limit: polls every 10 ms, at most a minute; this thread has nothing else to do. A half-close and a client that
            // died look alike here (both read 0, both poll as POLLHUP on macOS); either way it asks for nothing more, so its
            // watches go now (no git polling or host stats for it that minute), and a long wait pending ends on its own time.
            // Waited for after a read error too: what it asked is checked against the session it runs in, which is known
            // only while it's connected (`Callers.caller`).
            if ended { watches.drop(client.id) }
            for _ in 0..<6000 where pending.withLock({ $0 }) > 0 { usleep(10_000) }
            hungUp(client)
        }
    }

    /// Not a request: say so to whoever sent an id, rather than leave it waiting.
    private func refuse(_ line: Data, _ client: Connection) {
        guard let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"], id != .null,
            let refusal = try? Wire.line(
                Reply(id: id, error: RPCError(code: -32600, message: "invalid request")))
        else { return }
        client.send(refusal)
    }

    /// Quick, and only right in the order they were sent (keystrokes, a setting dragged, two sends; a saved layout or a
    /// terminal size that finished second must not win over the newer one): applied on the reader thread, one after
    /// another, calls and notifications alike (`Handled.inOrder`); a call's reply goes out in that order, or once the
    /// handler has it (`Handled.answerLater`). What has to wait for the reply comes after it (`Handled.replied`).
    private func answerInOrder(_ handler: any Handled.Type, _ req: Request, _ client: Connection) {
        let reply = replying(to: req, on: client), params = req.params ?? .null
        if handler.answerLater(params, in: self, conn: client.id, reply: reply) { return }
        let answered = Swift.Result { try answerNow(handler, params, conn: client.id) }
        reply(answered)
        if case .success = answered { handler.replied(in: self) }
    }

    /// Sends a call's result or error as its reply (a notification's has none); a failure goes to the log too.
    private func replying(to req: Request, on client: Connection) -> @Sendable (Swift.Result<Data, Error>) -> Void {
        let id = req.id ?? .null, notification = req.isNotification, method = req.method
        return { result in
            if case .failure(let error) = result { Self.log(method, failed: error, notification: notification) }
            guard !notification else { return }
            switch result {
            case .success(let data): client.send(Self.replyLine(id: id, result: data))
            case .failure(let error): if let line = Self.errorLine(id: id, error) { client.send(line) }
            }
        }
    }

    /// The connection ended: what it held goes with it.
    private func hungUp(_ client: Connection) {
        clients.remove(client.id)   // first: an attach finishing now sees it gone (Clients.isConnected)
        watches.drop(client.id)
        sessions.live.all.forEach { $0.detach(client.id) }
        lsp.closeAll(conn: client.id)   // its files: a server left with none stops a while later
        client.close()
    }

    /// Raw attach (`kelp attach`, the libghostty terminal): history then live output as plain bytes; whatever the client
    /// writes is the user's typing. Terminal replies (DA, kitty keyboard) flow back the same way, so the agent sees a real terminal.
    /// `SessionStream`'s `cols` / `rows`: the attaching terminal's, so a paused agent wakes at the size it's shown at.
    /// An ended session shows what it last printed (from its log), then the attach ends.
    private func stream(_ client: Connection, _ params: JSONValue, leftover: Data) {
        // Before waking: its status events must not land in the byte stream. It stays raw until `hungUp` removes it.
        clients.setRaw(client.id, true)
        // What it writes is typing, so it may type where session.write may: an agent's program only into its own sessions
        // (asked once, as it opens), and never while one asks a question (asked as each chunk comes: a question comes later).
        let caller = sessions.callers.caller(client.id)
        let held: Bool, session: String, size: (cols: UInt16, rows: UInt16)
        do {
            let method = try SessionStream.checked(params, self, conn: client.id)
            (session, size) = (method.id, Sessions.Launch.size(cols: method.cols, rows: method.rows))
            switch caller {
            case .user: held = false
            case .session(let own): held = try store.forAnAgent(own)
            default: held = true
            }
        } catch {
            client.send(Data("kelp: \(error.rpcMessage)\r\n".utf8))
            return
        }
        if sessions.existing(session) == nil,
            store.look("session \(session)", { try $0.session(session) })?.status == .exited
        {
            client.send(
                TerminalReplies.withoutQueries(
                    (try? sessions.liveSessionOrLog(session, bytes: LiveSession.ringLimit)) ?? Data()))
            return
        }
        let ls: LiveSession
        do { ls = try sessions.liveSession(session, cols: size.cols, rows: size.rows) } catch {
            // One Kelp has that didn't wake says why (its agent's CLI gone, its folder deleted), here and in the log.
            guard store.look("session \(session)", { try $0.session(session) }) != nil else {
                client.send(Data("kelp: no such session\r\n".utf8))
                return
            }
            let why = error.rpcMessage
            Log.session.error("\(session, privacy: .public) didn't wake for a terminal: \(why)")
            client.send(Data("kelp: \(why)\r\n".utf8))
            return
        }
        // Queued under the session's lock: no live output gets ahead of it. One paused at this moment ends the attach,
        // as the pause does for those already attached (`letGo`).
        guard ls.attach(client.id, send: { client.send($0) }) != nil else { return }
        let type = { (chunk: Data) -> Bool in
            // While the session asks, an agent's attach ends there, the chunk unsent (a terminal reply's payload can carry a
            // Return): dropped and going on, what it types around the question would join into one line.
            guard held, ls.asksSomething else {
                ls.userInput(chunk)
                return true
            }
            client.send(Data("\r\nkelp: That session asks a question, the user's to answer.\r\n".utf8))
            return false
        }
        var buf = [UInt8](repeating: 0, count: 65536)
        if leftover.isEmpty || type(leftover) {
            while true {
                let count = read(client.fd, &buf, buf.count)
                if count <= 0 || !type(Data(buf[0..<count])) { break }
            }
        }
        ls.detach(client.id)
    }

    private func respond(_ req: Request, conn client: Connection) async {
        let reply = replying(to: req, on: client)
        if !req.isNotification, let handler = Self.methods[req.method] as? any Handled.Type,
            await handler.respond(req.params ?? .null, in: self, conn: client.id, reply: reply)
        {
            return
        }
        do { reply(.success(try await answer(req.method, req.params ?? .null, conn: client.id))) } catch {
            reply(.failure(error))
        }
    }

    /// A call's refusal went back to its caller; a notification's failure (a layout or UI state not saved) and anything
    /// unexpected has only the log.
    static func log(_ method: String, failed error: Error, notification: Bool) {
        if let rpcError = error as? RPCError, !notification {
            Log.rpc.debug("\(method, privacy: .public) failed: \(rpcError.message)")
        } else {
            Log.rpc.error("\(method, privacy: .public) failed: \(error.rpcMessage)")
        }
    }

    /// A reply line around a result already encoded: the result isn't decoded and encoded again on its way out.
    static func replyLine(id: JSONValue, result: Data) -> Data {
        var line = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        line.append((try? JSONEncoder().encode(id)) ?? Data("null".utf8))
        line.append(Data(#","result":"#.utf8))
        line.append(result)
        line.append(Data("}\n".utf8))
        return line
    }
    static func errorLine(id: JSONValue, _ error: Error) -> Data? {
        try? Wire.line(Reply(id: id, error: (error as? RPCError) ?? .internalError("\(error)")))
    }
}
