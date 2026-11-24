import Core
import Foundation
import os

/// Finds what listens on a remote project's host, in one call over the host's shared connection. The folder a process
/// runs in says which project it belongs to, so an agent's server and a terminal's both count, and tmux or nohup
/// doesn't hide them. Only the user's own processes count.
enum HostPorts {
    struct Listener: Equatable { var port: Int, pid: Int32, command: String }

    /// Returns the script, which prints one `\036port pid program` line per listener. The \036 keeps a shell's greeting
    /// from passing for a line. It uses ss on Linux, and lsof where there is no ss.
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

/// The ports of remote projects' hosts that are brought to this Mac. It is one list for runs, for clicks and for the
/// ports asked for by hand. The list is kept in the store (`daemonState`, which only this class writes). A daemon
/// restart leaves the connection and its forwardings in place, and a dropped connection comes back with the same ports
/// here, so a page's address and cookies stay.
final class Forwards: Sendable {
    struct Record: Codable, Equatable, Sendable {
        /// `target` is the address as the host reaches it, such as "localhost:8000". `here` is the port on this Mac.
        var host, target: String, here: Int, worktree: String, manual: Bool
        /// `seen` is set once the port was seen listening. `misses` counts the looks in a row since then that didn't
        /// find it.
        var seen = false, misses = 0
        var port: Int { target.split(separator: ":").last.flatMap { Int($0) } ?? 0 }
    }
    private struct State: Sendable {
        var records: [Record]
        /// For each host, the connection that the forwardings were last made on.
        var connections: [String: String] = [:]
        /// For each workspace, the last list of its ports, for when the host can't be asked.
        var seen: [String: [PortsList.Port]] = [:]
    }
    private static let key = "ports.forwards"
    private let store: Store
    private let state: OSAllocatedUnfairLock<State>
    /// Makes each change and its save happen one at a time. If a save ran apart from its edit, an older copy could land
    /// after a newer one and stay. This lock is taken before `state`, never inside it, because `state` is never held
    /// during a save.
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

    /// Reads a target typed as "8000", "localhost:8000" or "db.internal:5432", and returns it as host:port.
    static func target(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces),
            full = Int(trimmed) != nil ? "localhost:" + trimmed : trimmed
        guard full.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/) != nil else {
            throw RPCError.invalidParams("“\(trimmed)” is no port or host:port.")
        }
        return full
    }

    /// Forwards `target` and returns its port on this Mac. That is the port it had before, or else the same number when
    /// it is free, or else the next free one of ten. It connects when the connection is gone, because this call means
    /// someone is asking for the page.
    func forward(_ target: String, in worktree: String, _ remote: RemoteHost, manual: Bool = false) throws -> Int {
        if remote.connection == nil { try remote.connect() }
        let old = state.withLock { s in s.records.first { $0.host == remote.host && $0.target == target } }
        let asked = target.split(separator: ":").last.flatMap { Int($0) } ?? 0
        let first = old?.here ?? (asked < 1024 ? asked + 10000 : asked)   // only root binds those here, so :80 → :10080
        for here in first..<first + 10 {
            do { try remote.control("forward", Self.spec(here, target)) } catch { continue }   // in use here, try next
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

    /// Returns a printed address as this Mac reaches it, or the address unchanged when its port can't be brought here.
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

    /// Returns the target that `port` forwards to in the workspace, because a port asked for by hand may be on another
    /// machine than the host.
    func target(port: Int, in worktree: String) -> String {
        state.withLock { s in s.records.first { $0.worktree == worktree && $0.port == port }?.target }
            ?? "localhost:\(port)"
    }

    /// Returns what the workspace's folder serves on the host, and the port each one has on this Mac. It never opens a
    /// connection, because Kelp must not redial a host that someone closed the lid on. Without a connection it returns
    /// the last answer, marked offline.
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
        // The host doesn't tell which session started a server. When the workspace has only one session, the server
        // counts as that session's.
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

    /// Makes the forwardings again on a new connection, which has none of the ones the last connection had. A
    /// forwarding never seen listening can't be told from a server long gone, so it is dropped here unless it was asked
    /// for by hand.
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

    /// Drops the forwarding of a server that stopped, two looks later, because a single look can fall during a restart.
    /// A forwarding asked for by hand stays.
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

    /// Returns the forwarding's spec, bound to this Mac only, whatever ~/.ssh/config says of GatewayPorts.
    static func spec(_ here: Int, _ target: String) -> String { "127.0.0.1:\(here):\(target)" }
}

extension Remotes {
    /// Whether `path` can be read without dialling: it's on this Mac, or its host's shared connection is open. A poll
    /// asks this first, because Kelp never dials a host by itself. It asks ssh, so it's for `offload`.
    func connected(_ path: String) -> Bool { of(path).map { $0.connection != nil } ?? true }
}

extension RemoteHost {
    /// The name the shared connection gives itself (its process), or nil when there is none. The name changes when the
    /// connection does.
    var connection: String? {
        Subprocess.printed(
            [ssh, "-o", "ControlPath=\(controlDir)/%C", "-O", "check", "--", host], path: "/usr/bin:/bin", timeout: 3)
    }

    /// Opens the shared connection and leaves it open. When it can't, it throws ssh's own reason, such as a key ssh
    /// can't use, a host it doesn't know, or a host that wants a password.
    func connect() throws {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin"
        let result = Log.session.attempt("connecting to \(host)") {
            try Subprocess.run([ssh] + sshArgs(tty: false) + ["true"], cwd: NSHomeDirectory(), env: env, timeLimit: 20)
        }
        guard let result, result.status == 0, !result.timedOut else {
            let said = result.flatMap {
                String(decoding: $0.stderr, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
            }
            throw RPCError.invalidParams("Can't reach \(host)" + (said.map { ": " + $0 } ?? "."))
        }
    }

    /// Runs `ssh -O`, which asks the master of the shared connection to add or drop a forwarding without a new login.
    func control(_ op: String, _ spec: String) throws {
        try Subprocess.output(
            [ssh, "-o", "ControlPath=\(controlDir)/%C", "-O", op, "-L", spec, "--", host], cwd: NSHomeDirectory())
    }
}
