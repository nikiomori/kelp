import Foundation
import os
import Core

/// What listens on a remote project's host, read in one call over its shared connection: the folder a process runs in says
/// whose it is, so an agent's server and a terminal's count, and a tmux or nohup doesn't hide them. Own processes only.
enum HostPorts {
    struct Listener: Equatable { var port: Int, pid: Int32, command: String }

    /// `\036port pid program` a line, so a shell's greeting can't pass for one. ss on Linux, lsof where there's none.
    static func script(_ path: String) -> String {
        let ss = #"ss -ltnpH 2>/dev/null | sed -n 's/.*[]:]\([0-9][0-9]*\)  *[^ ]*  *users:(("\([^"]*\)",pid=\([0-9]*\),.*/\1 \3 \2/p'"#
        let lsof = #"lsof -nP -iTCP -sTCP:LISTEN -u "$(id -u)" -Fpcn 2>/dev/null"#
            + #" | awk '/^p/{p=substr($0,2)} /^c/{c=substr($0,2)} /^n/{n=$0; sub(/.*:/,"",n)"#
            + #"; print n, p, c}'"#
        let folder = #"cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p')"#
        return ["cd \(RemoteHost.cdArg(path)) 2>/dev/null || exit 0", "here=$(pwd -P)",
                "if command -v ss >/dev/null 2>&1", "then \(ss)", "else \(lsof)",
                "fi | sort -un | while read -r port pid name", "do \(folder)",
                "case \"$cwd/\" in \"$here\"/*) printf '\\036%s %s %s\\n' \"$port\" \"$pid\" \"$name\";; esac", "done", "exit 0"].joined(separator: "; ")
    }

    static func parse(_ out: String) -> [Listener] {
        out.components(separatedBy: "\u{1E}").dropFirst().compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard f.count == 3, let port = Int(f[0]), let pid = Int32(f[1]) else { return nil }
            return Listener(port: port, pid: pid, command: f[2])
        }
    }
}

/// Ports of remote projects' hosts brought to this Mac, one list for runs, clicks and the ones asked for by hand. It's
/// kept in the store: a daemon restart leaves the connection and its forwardings, and a dropped connection comes back
/// with the same ports here, so a page's address and cookies stay.
final class Forwards: Sendable {
    struct Record: Codable, Equatable, Sendable {
        /// `target`: "localhost:8000", as the host reaches it. `here`: the port on this Mac.
        var host, target: String, here: Int, worktree: String, manual: Bool
        /// Seen listening once, then gone from this many looks in a row.
        var seen = false, misses = 0
        var port: Int { target.split(separator: ":").last.flatMap { Int($0) } ?? 0 }
    }
    private struct State: Sendable {
        var records: [Record]
        /// Host → the connection the forwardings were last made on.
        var connections: [String: String] = [:]
        /// Workspace → its last answer, for when the host can't be asked.
        var seen: [String: [PortsList.Port]] = [:]
    }
    private static let key = "ports.forwards"
    private let store: Store
    private let state: OSAllocatedUnfairLock<State>

    init(store: Store) {
        self.store = store
        let records = Log.store.attempt("reading the port forwardings") {
            try JSONDecoder().decode([Record].self, from: Data((try store.uiState(prefix: Self.key)[Self.key]?.string ?? "[]").utf8))
        } ?? []
        state = OSAllocatedUnfairLock(initialState: State(records: records))
    }

    private func change(_ edit: @Sendable (inout [Record]) -> Void) {
        let records = state.withLock { s in edit(&s.records); return s.records }
        Log.store.attempt("saving the port forwardings") {
            let text = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
            try store.setUIState(Self.key, .string(text))
        }
    }

    /// "8000", "localhost:8000" or "db.internal:5432".
    static func target(_ text: String) throws -> String {
        let t = text.trimmingCharacters(in: .whitespaces), full = Int(t) != nil ? "localhost:" + t : t
        guard full.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/) != nil else {
            throw RPCError.invalidParams("“\(t)” is no port or host:port.")
        }
        return full
    }

    /// The port on this Mac: the one it had, or the same number when it's free, else the next free one of ten. Connects
    /// when the connection is gone: this is someone asking for the page.
    func forward(_ target: String, in worktree: String, _ remote: RemoteHost, manual: Bool = false) throws -> Int {
        if remote.connection == nil { try remote.connect() }
        let old = state.withLock { s in s.records.first { $0.host == remote.host && $0.target == target } }
        let asked = target.split(separator: ":").last.flatMap { Int($0) } ?? 0
        let first = old?.here ?? (asked < 1024 ? asked + 10000 : asked)   // this Mac binds those only for root: :80 → :10080
        for here in first..<first + 10 {
            do { try remote.control("forward", Self.spec(here, target)) } catch { continue }   // taken here: the next one
            var r = old ?? Record(host: remote.host, target: target, here: here, worktree: worktree, manual: manual)
            r.here = here
            r.manual = r.manual || manual
            let record = r
            change { records in
                records.removeAll { $0.host == record.host && $0.target == record.target }
                records.append(record)
            }
            return here
        }
        throw RPCError.invalidParams("No free port on this Mac near \(first).")
    }

    /// A printed address as this Mac reaches it; as it was when it can't be brought here.
    func forward(url: String, in worktree: String, _ remote: RemoteHost) -> String {
        guard var u = URLComponents(string: url), let port = u.port else { return url }
        let target = (u.host == "127.0.0.1" ? "127.0.0.1" : "localhost") + ":\(port)"
        guard let here = Log.session.attempt("forwarding \(target)", { try forward(target, in: worktree, remote) }) else { return url }
        u.host = "localhost"
        u.port = here
        return u.string ?? url
    }

    func drop(port: Int, in worktree: String, _ remote: RemoteHost) {
        let gone = state.withLock { s in s.records.filter { $0.worktree == worktree && $0.port == port } }
        for r in gone { cancel(r, remote) }
        change { records in records.removeAll { gone.contains($0) } }
    }

    /// `port`'s record in the workspace: a port asked for by hand may be on another machine than the host.
    func target(port: Int, in worktree: String) -> String {
        state.withLock { s in s.records.first { $0.worktree == worktree && $0.port == port }?.target } ?? "localhost:\(port)"
    }

    /// What the workspace's folder serves on the host, and where each is here. Never opens a connection (Kelp must not
    /// redial a host someone closed the lid on): without one, the last answer, marked offline.
    func ports(_ w: Worktree, _ remote: RemoteHost, sessions: [String]) -> [PortsList.Port] {
        let args = [remote.ssh] + remote.sshArgs(tty: false) + ["sh -c " + RemoteHost.quote(HostPorts.script(remote.path))]
        guard let connection = remote.connection, let out = Sessions.run(args, path: "/usr/bin:/bin", timeout: 5) else {
            return state.withLock { $0.seen[w.id] ?? [] }.map {
                PortsList.Port(port: $0.port, pid: $0.pid, command: $0.command, session: $0.session, host: $0.host, here: $0.here, offline: true)
            }
        }
        restore(on: connection, remote)
        let found = HostPorts.parse(out)
        prune(w, found, remote)
        let records = state.withLock { s in s.records.filter { $0.worktree == w.id } }
        func here(_ port: Int) -> Int? { records.first { $0.port == port }?.here }
        // Which session started it isn't known on the host: alone in the workspace, it's that one.
        var ports = found.map {
            let session = sessions.count == 1 ? sessions[0] : ""
            return PortsList.Port(port: $0.port, pid: $0.pid, command: $0.command, session: session, host: remote.host, here: here($0.port))
        }
        for r in records where r.manual && !found.contains(where: { $0.port == r.port }) {
            ports.append(PortsList.Port(port: r.port, pid: 0, command: r.target, session: "", host: remote.host, here: r.here))
        }
        let answer = ports
        state.withLock { $0.seen[w.id] = answer }
        return answer
    }

    /// A new connection has none of the forwardings the last one had. One never seen listening can't be told from a
    /// server long gone, so it stops here.
    private func restore(on connection: String, _ remote: RemoteHost) {
        let again = state.withLock { s -> [Record] in
            defer { s.connections[remote.host] = connection }
            return s.connections[remote.host] == connection ? [] : s.records.filter { $0.host == remote.host }
        }
        for r in again where r.seen || r.manual {
            _ = Log.session.attempt("forwarding \(r.target) again") { try forward(r.target, in: r.worktree, remote, manual: r.manual) }
        }
        let host = remote.host
        change { $0.removeAll { r in again.contains(r) && r.host == host && !r.seen && !r.manual } }
    }

    /// A server that stopped takes its forwarding with it, two looks later: one look can fall in a restart.
    private func prune(_ w: Worktree, _ found: [HostPorts.Listener], _ remote: RemoteHost) {
        let id = w.id
        let open = found.map(\.port)
        change { records in
            for i in records.indices where records[i].worktree == id && !records[i].manual {
                let there = open.contains(records[i].port)
                records[i].seen = records[i].seen || there
                records[i].misses = there || !records[i].seen ? 0 : records[i].misses + 1
            }
        }
        let gone = state.withLock { s in s.records.filter { $0.worktree == id && $0.misses >= 2 } }
        for r in gone { cancel(r, remote) }
        if !gone.isEmpty { change { $0.removeAll { r in gone.contains(r) } } }
    }

    private func cancel(_ r: Record, _ remote: RemoteHost) {
        Log.session.attempt("ending the forwarding of \(r.target)") { try remote.control("cancel", Self.spec(r.here, r.target)) }
    }

    /// This Mac only, whatever ~/.ssh/config says of GatewayPorts.
    static func spec(_ here: Int, _ target: String) -> String { "127.0.0.1:\(here):\(target)" }
}

extension RemoteHost {
    /// The shared connection as it names itself (its process), nil with none. Changes when the connection does.
    var connection: String? {
        Sessions.run([ssh, "-o", "ControlPath=\(controlDir)/%C", "-O", "check", "--", host], path: "/usr/bin:/bin", timeout: 3)
    }

    /// Opens the shared connection and leaves it there.
    func connect() throws {
        guard Sessions.run([ssh] + sshArgs(tty: false) + ["true"], path: "/usr/bin:/bin", timeout: 20) != nil else {
            throw RPCError.invalidParams("Can't reach \(host).")
        }
    }

    /// `ssh -O`: asks the shared connection's master, which adds or drops a forwarding without a new login.
    func control(_ op: String, _ spec: String) throws {
        _ = try Git.run(["-o", "ControlPath=\(controlDir)/%C", "-O", op, "-L", spec, "--", host], cwd: NSHomeDirectory(), executable: ssh)
    }
}
