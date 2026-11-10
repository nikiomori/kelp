import Core
import Foundation
import os

/// What listens on a remote project's host, read in one call over its shared connection: the folder a process runs in says
/// whose it is, so an agent's server and a terminal's count, and a tmux or nohup doesn't hide them. Own processes only.
enum HostPorts {
    struct Listener: Equatable { var port: Int, pid: Int32, command: String }

    /// `\036port pid program` a line, so a shell's greeting can't pass for one. ss on Linux, lsof where there's none.
    static func script(_ path: String) -> String {
        let ss =
            #"ss -ltnpH 2>/dev/null | sed -n 's/.*[]:]\([0-9][0-9]*\)  *[^ ]*  *users:(("\([^"]*\)",pid=\([0-9]*\),.*/\1 \3 \2/p'"#
        let lsof =
            #"lsof -nP -iTCP -sTCP:LISTEN -u "$(id -u)" -Fpcn 2>/dev/null"#
            + #" | awk '/^p/{p=substr($0,2)} /^c/{c=substr($0,2)} /^n/{n=$0; sub(/.*:/,"",n)"#
            + #"; print n, p, c}'"#
        let folder =
            #"cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p')"#
        return [
            "cd \(RemoteHost.cdArg(path)) 2>/dev/null || exit 0", "here=$(pwd -P)",
            "if command -v ss >/dev/null 2>&1", "then \(ss)", "else \(lsof)",
            "fi | sort -un | while read -r port pid name", "do \(folder)",
            "case \"$cwd/\" in \"$here\"/*) printf '\\036%s %s %s\\n' \"$port\" \"$pid\" \"$name\";; esac", "done",
            "exit 0"
        ].joined(separator: "; ")
    }

    static func parse(_ out: String) -> [Listener] {
        out.components(separatedBy: "\u{1E}").dropFirst().compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard fields.count == 3, let port = Int(fields[0]), let pid = Int32(fields[1]) else { return nil }
            return Listener(port: port, pid: pid, command: fields[2])
        }
    }
}

/// Ports of remote projects' hosts brought to this Mac, one list for runs, clicks and the ones asked for by hand. It's
/// kept in the store (`daemonState`, which only this writes): a daemon restart leaves the connection and its
/// forwardings, and a dropped connection comes back with the same ports here, so a page's address and cookies stay.
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
    /// Each change and its save, one at a time: saved apart from its edit, an older copy could land after a newer one
    /// and stay. Taken before `state`, never inside it (that lock is held for no save).
    private let saving = NSLock()

    init(store: Store) {
        self.store = store
        let records =
            Log.store.attempt("reading the port forwardings") {
                try store.daemonState(Self.key, as: [Record].self) ?? []
            } ?? []
        state = OSAllocatedUnfairLock(initialState: State(records: records))
    }

    func change(_ edit: @Sendable (inout [Record]) -> Void) {
        saving.withLock {
            let records = state.withLock { current in
                edit(&current.records)
                return current.records
            }
            Log.store.attempt("saving the port forwardings") { try store.setDaemonState(Self.key, records) }
        }
    }

    /// "8000", "localhost:8000" or "db.internal:5432".
    static func target(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces),
            full = Int(trimmed) != nil ? "localhost:" + trimmed : trimmed
        guard full.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/) != nil else {
            throw RPCError.invalidParams("“\(trimmed)” is no port or host:port.")
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
            var updated =
                old ?? Record(host: remote.host, target: target, here: here, worktree: worktree, manual: manual)
            updated.here = here
            updated.manual = updated.manual || manual
            let record = updated
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
        guard var components = URLComponents(string: url), let port = components.port else { return url }
        let target = (components.host == "127.0.0.1" ? "127.0.0.1" : "localhost") + ":\(port)"
        guard let here = Log.session.attempt("forwarding \(target)", { try forward(target, in: worktree, remote) })
        else { return url }
        components.host = "localhost"
        components.port = here
        return components.string ?? url
    }

    func drop(port: Int, in worktree: String, _ remote: RemoteHost) {
        let gone = state.withLock { s in s.records.filter { $0.worktree == worktree && $0.port == port } }
        for record in gone { cancel(record, remote) }
        change { records in records.removeAll { gone.contains($0) } }
    }

    /// `port`'s record in the workspace: a port asked for by hand may be on another machine than the host.
    func target(port: Int, in worktree: String) -> String {
        state.withLock { s in s.records.first { $0.worktree == worktree && $0.port == port }?.target }
            ?? "localhost:\(port)"
    }

    /// What the workspace's folder serves on the host, and where each is here. Never opens a connection (Kelp must not
    /// redial a host someone closed the lid on): without one, the last answer, marked offline.
    func ports(_ worktree: Worktree, _ remote: RemoteHost, sessions: [String]) -> [PortsList.Port] {
        let args =
            [remote.ssh] + remote.sshArgs(tty: false) + ["sh -c " + ShellQuote.word(HostPorts.script(remote.path))]
        guard let connection = remote.connection, let out = Subprocess.printed(args, path: "/usr/bin:/bin", timeout: 5)
        else {
            return state.withLock { $0.seen[worktree.id] ?? [] }.map {
                PortsList.Port(
                    port: $0.port, pid: $0.pid, command: $0.command, session: $0.session, host: $0.host, here: $0.here,
                    offline: true)
            }
        }
        restore(on: connection, remote)
        let found = HostPorts.parse(out)
        prune(worktree, found, remote)
        let records = state.withLock { s in s.records.filter { $0.worktree == worktree.id } }
        func here(_ port: Int) -> Int? { records.first { $0.port == port }?.here }
        // Which session started it isn't known on the host: alone in the workspace, it's that one.
        var ports = found.map {
            let session = sessions.count == 1 ? sessions[0] : ""
            return PortsList.Port(
                port: $0.port, pid: $0.pid, command: $0.command, session: session, host: remote.host,
                here: here($0.port))
        }
        for record in records where record.manual && !found.contains(where: { $0.port == record.port }) {
            ports.append(
                PortsList.Port(
                    port: record.port, pid: 0, command: record.target, session: "", host: remote.host, here: record.here
                ))
        }
        let answer = ports
        state.withLock { $0.seen[worktree.id] = answer }
        return answer
    }

    /// A new connection has none of the forwardings the last one had. One never seen listening can't be told from a
    /// server long gone, so it stops here.
    private func restore(on connection: String, _ remote: RemoteHost) {
        let again = state.withLock { current -> [Record] in
            defer { current.connections[remote.host] = connection }
            return current.connections[remote.host] == connection
                ? [] : current.records.filter { $0.host == remote.host }
        }
        for record in again where record.seen || record.manual {
            _ = Log.session.attempt("forwarding \(record.target) again") {
                try forward(record.target, in: record.worktree, remote, manual: record.manual)
            }
        }
        let host = remote.host
        change { $0.removeAll { r in again.contains(r) && r.host == host && !r.seen && !r.manual } }
    }

    /// A server that stopped takes its forwarding with it, two looks later: one look can fall in a restart.
    private func prune(_ worktree: Worktree, _ found: [HostPorts.Listener], _ remote: RemoteHost) {
        let id = worktree.id
        let open = found.map(\.port)
        change { records in
            for index in records.indices where records[index].worktree == id && !records[index].manual {
                let there = open.contains(records[index].port)
                records[index].seen = records[index].seen || there
                records[index].misses = there || !records[index].seen ? 0 : records[index].misses + 1
            }
        }
        let gone = state.withLock { s in s.records.filter { $0.worktree == id && $0.misses >= 2 } }
        for record in gone { cancel(record, remote) }
        if !gone.isEmpty { change { $0.removeAll { r in gone.contains(r) } } }
    }

    private func cancel(_ record: Record, _ remote: RemoteHost) {
        Log.session.attempt("ending the forwarding of \(record.target)") {
            try remote.control("cancel", Self.spec(record.here, record.target))
        }
    }

    /// This Mac only, whatever ~/.ssh/config says of GatewayPorts.
    static func spec(_ here: Int, _ target: String) -> String { "127.0.0.1:\(here):\(target)" }
}

extension RemoteHost {
    /// The shared connection as it names itself (its process), nil with none. Changes when the connection does.
    var connection: String? {
        Subprocess.printed(
            [ssh, "-o", "ControlPath=\(controlDir)/%C", "-O", "check", "--", host], path: "/usr/bin:/bin", timeout: 3)
    }

    /// Opens the shared connection and leaves it there.
    func connect() throws {
        guard Subprocess.printed([ssh] + sshArgs(tty: false) + ["true"], path: "/usr/bin:/bin", timeout: 20) != nil
        else {
            throw RPCError.invalidParams("Can't reach \(host).")
        }
    }

    /// `ssh -O`: asks the shared connection's master, which adds or drops a forwarding without a new login.
    func control(_ op: String, _ spec: String) throws {
        _ = try Git.run(
            ["-o", "ControlPath=\(controlDir)/%C", "-O", op, "-L", spec, "--", host], cwd: NSHomeDirectory(),
            executable: ssh)
    }
}
