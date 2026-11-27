import Agents
import Core
import Foundation
import os

/// Lets an agent on a remote project's host drive a page in Kelp's window with `kelp browser`. Each such session gets
/// a socket here (`macSocket`), and the host's shared connection brings a socket on the host to it (`ssh -O forward
/// -R`), so no new login is made. `kelp` on the host is a sh script (`HostKelp`) that sends its words here; they are
/// read as the CLI reads them (`BrowserWords`) and answered as the session's agent, held to an agent's rules. The
/// socket speaks only `kelp browser`, for that one session.
/// The page sees the host's network (`HostBrowser+Run.swift`): its localhost through forwarded ports, the rest through
/// a SOCKS proxy on the host.
final class HostBrowser: Sendable {
    /// The session's channel: its host, and its folder there.
    struct Channel: Sendable {
        let remote: RemoteHost
        var dir: String
    }
    private struct State {
        var channels: [String: Channel] = [:]
        /// The socket's listener here, for each channel.
        var sources: [String: any DispatchSourceRead] = [:]
        /// Each host's SOCKS proxy here, and the connection it was made on.
        var socks: [String: (port: Int, connection: String)] = [:]
        /// Where a recording under way goes on the host, by session.
        var recordings: [String: (here: String, there: String)] = [:]
    }
    let root: URL, remotes: Remotes, forwards: Forwards, store: Store
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    /// Answers one `ui.browser` or `ui.browser.ask` as the session's agent. The daemon sets it once it can answer.
    let answer = OSAllocatedUnfairLock<(@Sendable (String, any Answered) async throws -> JSONValue)?>(initialState: nil)
    private let queue = DispatchQueue(label: "kelp.host-browser")

    /// What a page driven from a host is told when it opens: whose network it is on (`host`), the SOCKS proxy that
    /// takes it there (`proxy`), and the ports of this Mac's loopback forwarded from there (`ports`), the only ones it
    /// may reach. Set around a host's `open` (`ui.browser` puts it in the page's args, and drops one sent otherwise).
    @TaskLocal static var page: JSONValue?

    init(root: URL, remotes: Remotes, forwards: Forwards, store: Store) {
        self.root = root
        self.remotes = remotes
        self.forwards = forwards
        self.store = store
    }

    /// Whether a session gets the channel: an agent on a host, in tmux there, that takes Kelp's skills as a plugin
    /// folder (Claude Code). Other agents read skills from the project's folder, which is a later step.
    static func wanted(_ manifest: AgentManifest, tmux: String?) -> Bool {
        tmux != nil && manifest.pluginDirFlag != nil && Session.isAgent(manifest.id)
    }

    /// Listens again for a session the kelpd before this one ran: the host's connection kept its forwarding to this
    /// socket. Its folder there is learnt from its first call (`run`).
    func adopted(_ rec: Session, _ manifest: AgentManifest) {
        guard let remote = remotes.of(rec.cwd), Self.wanted(manifest, tmux: rec.tmux) else { return }
        Log.session.attempt("listening for kelp browser from \(remote.host)") {
            try listen(rec.id, remote: remote, dir: "")
        }
    }

    /// The socket here for a session's channel. It sits beside the shared connections' sockets, whose folder has a
    /// short path, because a socket's path fits in 104 bytes.
    func macSocket(_ session: String) -> String { remotes.controlDir + "/b-" + session.lowercased().prefix(13) }

    /// Puts `kelp` and the browser skill on the host, listens here, and brings the session's socket from the host. It
    /// runs as the session starts or is attached again, over the connection that is opened for it anyway. Returns the
    /// folder on the host, and the file there that says the project is a web app.
    func prepare(_ session: String, remote: RemoteHost) throws -> (dir: String, webApp: String?) {
        endEnded()
        guard !HostKelp.shim.isEmpty else { throw RPCError.internalError("Kelp's kelp for hosts is missing.") }
        let skill = HostKelp.skill(skillText() ?? "", host: remote.host)
        let script = HostKelp.setup(session: session, project: remote.path, skill: skill)
        let out = String(decoding: try remote.run("sh -s", stdin: Data(script.utf8), timeLimit: 20), as: UTF8.self)
        guard let made = HostKelp.parse(out) else {
            throw RPCError.internalError("Kelp couldn't set up kelp browser on \(remote.host).")
        }
        try listen(session, remote: remote, dir: made.dir)
        // A forwarding that the connection still holds from before was left without its file just now, so it is
        // dropped first (when there is none, ssh says so, and that is all) and made again.
        let spec = made.dir + "/" + HostKelp.socketName(session) + ":" + macSocket(session)
        _ = Self.cancel(remote, spec)
        Log.session.attempt("bringing kelp browser's socket from \(remote.host)") {
            try Self.control(remote, "forward", "-R", spec)
        }
        return made
    }

    /// The browser skill the app wrote into this home.
    private func skillText() -> String? {
        let file = Paths.agentSkills(in: root).appendingPathComponent("kelp-browser/skills/kelp-browser/SKILL.md")
        return FileManager.default.contents(atPath: file.path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Listens on the session's socket here, unless it already does. A session taken over from the kelpd before this
    /// one gets it again here (`dir` unknown until its next start), since the connection kept its forwarding.
    func listen(_ session: String, remote: RemoteHost, dir: String) throws {
        if state.withLock({ $0.channels[session] }) != nil {
            if !dir.isEmpty { state.withLock { $0.channels[session]?.dir = dir } }
            return
        }
        let path = macSocket(session), fd = try Unix.listen(path)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }
        source.setEventHandler { [weak self] in
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            guard Unix.peerIsUs(conn) else {   // the connection's own ssh, run as this user
                close(conn)
                return
            }
            Unix.noSigPipe(conn)
            Thread.detachNewThread { [weak self] in
                self?.serve(conn, session)
                close(conn)
            }
        }
        state.withLock {
            $0.channels[session] = Channel(remote: remote, dir: dir)
            $0.sources[session] = source
        }
        source.resume()
    }

    /// Ends a session's channel: its socket here goes, and the forwarding, while the connection is there.
    func end(_ session: String) {
        let (channel, source) = state.withLock { s in
            s.recordings[session] = nil
            return (s.channels.removeValue(forKey: session), s.sources.removeValue(forKey: session))
        }
        source?.cancel()
        guard let channel, !channel.dir.isEmpty else { return }
        _ = Self.cancel(channel.remote, channel.dir + "/" + HostKelp.socketName(session) + ":" + macSocket(session))
    }

    /// Ends the channels of sessions that ended since, as a new one is set up.
    private func endEnded() {
        for session in state.withLock({ Array($0.channels.keys) })
        where store.look("session \(session)", { try $0.session(session) })??.status ?? .exited == .exited {
            end(session)
        }
    }

    /// The workspace a session works in, which its page opens in.
    func worktree(_ session: String) -> String? {
        store.look("session \(session)", { try $0.session(session) })??.worktreeId
    }

    /// Drops a forwarding of the host's connection. Returns whether there was one to drop.
    static func cancel(_ remote: RemoteHost, _ spec: String) -> Bool {
        let args = [
            remote.ssh, "-o", "ControlPath=\(remote.controlDir)/%C", "-O", "cancel", "-R", spec, "--", remote.host
        ]
        return Subprocess.printed(args, path: "/usr/bin:/bin", timeout: 10) != nil
    }

    func channel(_ session: String) -> Channel? { state.withLock { $0.channels[session] } }

    /// Asks the master of the host's shared connection to add or drop a forwarding (`-R`, `-D`), with no new login.
    static func control(_ remote: RemoteHost, _ op: String, _ kind: String, _ spec: String) throws {
        try Subprocess.output(
            [remote.ssh, "-o", "ControlPath=\(remote.controlDir)/%C", "-O", op, kind, spec, "--", remote.host],
            cwd: NSHomeDirectory(), timeLimit: 10)
    }

    /// The SOCKS proxy here that reaches the network from the host, made on the host's connection once, and again on a
    /// new connection. Nil when the host has no connection, or refuses it.
    func socks(_ remote: RemoteHost) -> Int? {
        guard let connection = remote.connection else { return nil }
        if let made = state.withLock({ $0.socks[remote.host] }), made.connection == connection { return made.port }
        guard let port = Unix.freePort() else { return nil }
        let made: Void? = Log.session.attempt("a SOCKS proxy through \(remote.host)") {
            try Self.control(remote, "forward", "-D", "127.0.0.1:\(port)")
        }
        guard made != nil else { return nil }
        state.withLock { $0.socks[remote.host] = (port, connection) }
        return port
    }

    /// Where a recording under way for the session goes, here and on the host.
    func recording(_ session: String, _ paths: (here: String, there: String)?) {
        state.withLock { $0.recordings[session] = paths }
    }
    func recording(_ session: String) -> (here: String, there: String)? {
        state.withLock { $0.recordings[session] }
    }
}

// MARK: - the socket's requests

extension HostBrowser {
    /// The most a request may send: words, and a script or a list of steps on stdin. Files go the other way (kelpd
    /// reads them on the host).
    static let requestLimit = 4_000_000

    /// Reads one request from `kelp` on the host (HTTP, as curl sends it), answers it line by line, and returns.
    func serve(_ fd: Int32, _ session: String) {
        guard let body = Self.readRequest(fd) else { return }
        _ = Unix.writeAll(fd, Data("HTTP/1.0 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n".utf8))
        let say = Say { line in _ = Unix.writeAll(fd, Data((line + "\n").utf8)) }
        guard let request = Self.request(body) else {
            say.error("kelp browser: Kelp couldn't read what was sent.")
            return say.exit(1)
        }
        say.exit(run(session, request, say))
    }

    /// What `kelp` on the host sends: its socket, the folder it runs in, its words, and stdin (when the words need it).
    /// Each word ends with a NUL, after the socket, the folder and the count of words.
    struct Request: Equatable {
        var socket: String, cwd: String, words: [String], stdin: String
    }

    static func request(_ body: Data) -> Request? {
        var rest = body[...]
        func field() -> String? {
            guard let end = rest.firstIndex(of: 0) else { return nil }
            defer { rest = rest[(end + 1)...] }
            return String(decoding: rest[..<end], as: UTF8.self)
        }
        guard let socket = field(), let cwd = field(), let count = field().flatMap({ Int($0) }),
            (0...10_000).contains(count)
        else {
            return nil
        }
        var words: [String] = []
        for _ in 0..<count {
            guard let word = field() else { return nil }
            words.append(word)
        }
        return Request(socket: socket, cwd: cwd, words: words, stdin: String(decoding: rest, as: UTF8.self))
    }

    /// Reads an HTTP request's head and returns its body, or nil for one that isn't whole or is too big.
    static func readRequest(_ fd: Int32) -> Data? {
        var data = Data(), buf = [UInt8](repeating: 0, count: 65536)
        var head: Range<Data.Index>?
        while head == nil {
            let count = read(fd, &buf, buf.count)
            guard count > 0, data.count < 65536 else { return nil }
            data.append(contentsOf: buf[0..<count])
            head = data.range(of: Data("\r\n\r\n".utf8))
        }
        guard let head else { return nil }
        let lines = String(decoding: data[..<head.lowerBound], as: UTF8.self).lowercased().components(
            separatedBy: "\r\n")
        let length =
            lines.lazy.compactMap { line -> Int? in
                guard line.hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }.first ?? 0
        guard length <= requestLimit else { return nil }
        var body = Data(data[head.upperBound...])
        while body.count < length {
            let count = read(fd, &buf, min(buf.count, length - body.count))
            guard count > 0 else { return nil }
            body.append(contentsOf: buf[0..<count])
        }
        return body.prefix(length)
    }

    /// Writes the lines of an answer as `kelp` on the host reads them: `o` for stdout, `e` for stderr, `x` the exit
    /// code.
    struct Say: Sendable {
        let line: @Sendable (String) -> Void
        func out(_ text: String) { text.components(separatedBy: "\n").forEach { line("o " + $0) } }
        func error(_ text: String) { text.components(separatedBy: "\n").forEach { line("e " + $0) } }
        func exit(_ code: Int32) { line("x \(code)") }
    }
}
