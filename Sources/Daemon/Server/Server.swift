import Agents
import Core
import Foundation
import os

// The socket's side of the daemon: each connection's reader, how a request is answered and its reply goes out, a
// terminal's raw stream (`session.stream`), a method answered as a client would get it (`ask`, for what the watches
// read), and the records every client is sent as they change.

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
        // A client may be accepted just as this daemon stopped or handed over, because cancelling doesn't stop an
        // accept already running. It is added first and checked after, so either the stop's hang-up catches it or it is
        // hung up here. Its reader then reads the end and cleans up as for any other client, and the client connects to
        // the next daemon.
        if !isServing { client.hangUp() }
        Thread.detachNewThread { [self] in
            // Looks up who the client is before anything it sent is read, while its program is surely still there. This
            // runs here, not on the accept queue, because the lookup for a tmux pane asks tmux (`Callers.tmuxPane`).
            _ = callers.caller(client.id)
            var received = LineBuffer()
            var buf = [UInt8](repeating: 0, count: 65536)
            var spoke = false
            // How many of this client's requests are still being answered. Past `pendingLimit`, more are refused
            // instead of queuing forever.
            let pending = OSAllocatedUnfairLock(initialState: 0)
            var ended = false   // the client sent all it had (`printf … | nc -U`), but its requests are still answered
            reading: while true {
                let count = read(fd, &buf, buf.count)
                if count <= 0 {
                    ended = count == 0
                    break
                }
                let lines = received.append(Data(buf[0..<count]))
                // A line longer than any request (a 50 MB file saved, escaped) isn't a request, so hang up rather than
                // keep it all.
                guard received.pending <= Self.lineLimit else {
                    Log.rpc.error("hung up on a client whose line passed \(Self.lineLimit) bytes with no end")
                    break reading
                }
                for (index, line) in lines.enumerated() {
                    guard let req = try? JSONDecoder().decode(Request.self, from: line) else {
                        refuse(line, client)
                        continue
                    }
                    // The client speaks JSON-RPC after all (it came in raw, Clients.add), so it gets events from now
                    // on. A first line that asks for none (`client.events`, as `kelp attach`'s control line does) is
                    // muted in the same step: a broadcast in between would reach it before its answer.
                    if !spoke {
                        spoke = true
                        if req.method != SessionStream.name {
                            let unheard = req.method == ClientEvents.name && req.params?["events"] == .bool(false)
                            clients.speaksJSON(client.id, muted: unheard)
                        }
                    }
                    if let handler = Self.methods[req.method] as? any Handled.Type, handler.inOrder {
                        answerInOrder(handler, req, client)
                        continue
                    }
                    // session.stream isn't a call. It ends JSON-RPC on this connection, which becomes a raw byte pipe
                    // (kelp attach).
                    if req.method == SessionStream.name {
                        // What came after this line in the same read already belongs to the stream: its whole lines,
                        // then the rest.
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
            // Limit: this polls every 10 ms, for at most a minute, while the client's pending requests finish; this
            // thread has nothing else to do. A half-close and a client that died look alike here (both read 0, both
            // poll as POLLHUP on macOS). Either way the client asks for nothing more, so its watches go now (no git
            // polling or host stats for it that minute), and a long wait still pending ends in its own time.
            // The wait happens after a read error too, because what the client asked is checked against the session it
            // runs in, which is known only while it's connected (`Callers.caller`).
            if ended { watches.drop(client.id) }
            for _ in 0..<6000 where pending.withLock({ $0 }) > 0 { usleep(10_000) }
            hungUp(client)
        }
    }

    /// Answers a line that isn't a request with an error, when the line has an id, rather than leave the sender
    /// waiting.
    private func refuse(_ line: Data, _ client: Connection) {
        guard let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"], id != .null,
            let refusal = try? Wire.line(
                Reply(id: id, error: RPCError(code: -32600, message: "invalid request")))
        else { return }
        client.send(refusal)
    }

    /// Answers a method that is quick and right only in the order sent (keystrokes, a setting dragged, two sends; a
    /// saved layout or a terminal size that finished second must not win over the newer one). These are applied on the
    /// reader thread one after another, calls and notifications alike (`Handled.inOrder`). A call's reply goes out in
    /// that order, or once the handler has it (`Handled.answerLater`). What has to wait for the reply runs after it
    /// (`Handled.replied`).
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

    /// Cleans up after a connection ended: what it held goes with it.
    private func hungUp(_ client: Connection) {
        clients.remove(client.id)   // first: an attach finishing now sees it gone (Clients.isConnected)
        watches.drop(client.id)
        sessions.live.all.forEach { $0.detach(client.id) }
        lsp.closeAll(conn: client.id)   // closes its files; a server left with none stops a while later
        client.close()
    }

    /// Serves a raw attach (`kelp attach`, the libghostty terminal): the history, then live output, as plain bytes.
    /// Whatever the client writes is the user's typing. Terminal replies (DA, kitty keyboard) flow back the same way,
    /// so the agent sees a real terminal.
    /// `SessionStream`'s `cols` / `rows` are the attaching terminal's size, so a paused agent wakes at the size it's
    /// shown at. An ended session shows what it last printed (from its log), and then the attach ends.
    private func stream(_ client: Connection, _ params: JSONValue, leftover: Data) {
        // Set raw before waking, so the session's status events don't land in the byte stream. The client stays raw
        // until `hungUp` removes it.
        clients.setRaw(client.id, true)
        // What the client writes is typing, so it may type only where session.write may. An agent's program types only
        // into its own sessions (checked once, as the stream opens), and never while the session asks a question
        // (checked for each chunk, because a question can come later).
        let caller = callers.caller(client.id)
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
            // A session Kelp has that didn't wake says why (its agent's CLI gone, its folder deleted), here and in the
            // log.
            guard store.look("session \(session)", { try $0.session(session) }) != nil else {
                client.send(Data("kelp: no such session\r\n".utf8))
                return
            }
            let why = error.rpcMessage
            Log.session.error("\(session, privacy: .public) didn't wake for a terminal: \(why)")
            client.send(Data("kelp: \(why)\r\n".utf8))
            return
        }
        // The history is queued under the session's lock, so no live output gets ahead of it. A session paused at this
        // moment ends the attach, as the pause does for those already attached (`letGo`).
        guard ls.attach(client.id, send: { client.send($0) }) != nil else { return }
        let type = { (chunk: Data) -> Bool in
            // While the session asks a question, an agent's attach ends there and the chunk isn't sent (a terminal
            // reply's payload can carry a Return). If the chunk were dropped and the attach went on, what the agent
            // types around the question would join into one line.
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

    /// Logs a failed method. A call's refusal already went back to its caller, so it is logged at debug level. A
    /// notification's failure (a layout or UI state not saved) and anything unexpected has only the log.
    static func log(_ method: String, failed error: Error, notification: Bool) {
        if let rpcError = error as? RPCError, !notification {
            Log.rpc.debug("\(method, privacy: .public) failed: \(rpcError.message)")
        } else {
            Log.rpc.error("\(method, privacy: .public) failed: \(error.rpcMessage)")
        }
    }

    /// Wraps a result that is already encoded in a reply line, so the result isn't decoded and encoded again on its way
    /// out.
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

    /// Answers a method as a client would get it (refusals and error mapping included) and returns its result as its
    /// type.
    func ask<M: Answered>(_ method: M) async throws -> M.Result {
        try JSONDecoder().decode(M.Result.self, from: await answer(M.name, try method.params() ?? .null, conn: -1))
    }

    /// Answers a host's `kelp browser` as its session's agent is answered on this Mac (`HostBrowser`): held to an
    /// agent's rules, the page the agent's own.
    func answerFromHost(_ session: String, _ method: any Answered) async throws -> JSONValue {
        let caller = Caller.session(session)
        try allow(method, conn: -1, caller: caller)
        let relay = BrowserRelay.of(self)
        do {
            return try await Sessions.$asker.withValue(caller.origin) {
                switch method {
                case let ask as UIBrowserAsk: try await ask.handle(relay, conn: -1)
                case let browse as UIBrowser: try await browse.handle(relay, conn: -1)
                default: throw RPCError.methodNotFound
                }
            }
        } catch { throw Self.rpc(error) }
    }

    /// Answers from now on what comes from outside the socket: a phone's calls, as the daemon's own (`conn` -1, which
    /// counts as the user's, because an Allow tapped on the phone has to), and a host's `kelp browser`, as its agent.
    /// A session handed over from the kelpd before gets its socket for the host again.
    func hearFromAfar() {
        sessions.phone.hear(
            .started { [weak self] method, params in
                guard let self else { throw RPCError.internalError("The background service stopped.") }
                return try await answer(method, params, conn: -1)
            })
        let hosts = sessions.setup.hostBrowser
        hosts.answer.withLock {
            $0 = { [weak self] session, method in
                guard let self else { throw RPCError.internalError("The background service stopped.") }
                return try await answerFromHost(session, method)
            }
        }
        for ls in sessions.live.all {
            if let manifest = sessions.setup.agent(ls.snapshot.agent) { hosts.adopted(ls.snapshot, manifest) }
        }
    }

    /// Like `ask` but without the trip through JSON, for what a watch reads itself, often and large. It returns the
    /// handler's result as it is (a file list holds up to 200k paths, which `ask` encoded and decoded, and the event
    /// then encoded again). This is Kelp's own read, so there is no caller to check. Errors come as `ask` gives them.
    func direct<M: Handled>(_ method: M) async throws -> M.Result where M.Service: Sendable {
        let service = M.Service.of(self)
        do { return try await offload(quick: M.quick) { try method.handle(service, conn: -1) } } catch {
            throw Self.rpc(error)
        }
    }

    /// Sends every client a project or workspace record that changed, or a record that went (clients keep their lists
    /// from these).
    func recordChanged(_ change: Store.Change) {
        switch change {
        case .repo(let repo): notify(repo)
        case .worktree(let worktree): notify(worktree)
        case .repoRemoved(let id): notify(RemovedEvent(repo: id))
        case .worktreeRemoved(let id): notify(RemovedEvent(worktree: id))
        case .sessionRemoved(let id, _):
            notify(RemovedEvent(session: id))
            sessions.phone.hear(.removed(id))
        case .sessionEnded: break   // its record went out as it was saved
        }
    }
}
