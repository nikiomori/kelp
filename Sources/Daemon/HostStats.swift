import Core
import Foundation
import os

/// What a remote project's host is doing (`host.stats`): one `sh` over its shared connection reads /proc, df, ss, tmux
/// and ps, about 0.4 s with the connection open (0.3 of it is the CPU's two looks). Linux in full; on macOS and BSD what
/// they share (load, disk, processes).
typealias HostErrors = OSAllocatedUnfairLock<[String: String]>

enum HostStatsReader {
    /// A section a line `\036name`, so a greeting the shell prints can't pass for one.
    static let script = [
        #"s() { printf '\036%s\n' "$1"; }"#,
        #"s os; (. /etc/os-release && [ -n "$PRETTY_NAME" ] && echo "$PRETTY_NAME") 2>/dev/null || uname -sr"#,
        "s cores; getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null",
        "s uptime; cut -d' ' -f1 /proc/uptime 2>/dev/null",
        "s load; cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null",
        "s cpu; if [ -r /proc/stat ]; then head -1 /proc/stat; sleep 0.3; head -1 /proc/stat; fi",
        "s mem; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null",
        "s disk; df -kP / 2>/dev/null | tail -1",
        "s ports; if command -v ss >/dev/null 2>&1; then ss -ltnH | awk '{print $4}'; else netstat -an 2>/dev/null | awk '/LISTEN/ {print $4}'; fi",
        "s tmux; tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null",
        "s ps; ps -axo pid=,ppid=,user=,pcpu=,rss=,etime=,args= 2>/dev/null",
        "exit 0"
    ].joined(separator: "\n")

    /// `errors`: host → why its last connection failed, in ssh's words, until one works.
    static func read(_ remote: RemoteHost, connect: Bool, sessions: [Session], errors: HostErrors) -> HostStats {
        let host = remote.host
        if !connect, remote.connection == nil {
            return HostStats(host: host, connected: false, error: errors.withLock { $0[host] })
        }
        let argv = [remote.ssh] + remote.sshArgs(tty: false) + ["sh -c " + IDE.shellWord(script)]
        let out = Log.session.attempt("reading \(host)'s stats") {
            try Subprocess.run(
                argv, cwd: NSHomeDirectory(), env: ProcessInfo.processInfo.environment, timeLimit: 25, limit: 4 << 20)
        }
        guard let out, out.status == 0, !out.timedOut else {
            let said = out.map { String(decoding: $0.stderr, as: UTF8.self) } ?? ""
            let why =
                said.split(whereSeparator: \.isNewline).last.map(String.init)
                ?? (out?.timedOut == true ? "ssh timed out" : "ssh failed")
            errors.withLock { $0[host] = why }
            return HostStats(host: host, connected: false, error: why)
        }
        errors.withLock { $0[host] = nil }
        let owner = Dictionary(sessions.compactMap { s in Sessions.tmuxName(s).map { ($0, s) } }) { a, b in
            a.status == .exited ? b : a
        }.mapValues(\.id)
        return parse(String(decoding: out.stdout, as: UTF8.self), host: host, owner: owner)
    }

    /// Closes the shared connection; what runs in tmux there goes on.
    static func disconnect(_ remote: RemoteHost, errors: HostErrors) {
        _ = Sessions.run(
            [remote.ssh, "-o", "ControlPath=\(remote.controlDir)/%C", "-O", "exit", "--", remote.host],
            path: "/usr/bin:/bin", timeout: 5)
        errors.withLock { $0[remote.host] = nil }
    }

    // MARK: reading the answer

    /// `owner`: tmux session name → the Kelp session in it.
    static func parse(_ text: String, host: String, owner: [String: String]) -> HostStats {
        var sections: [String: [String]] = [:]
        for chunk in text.components(separatedBy: "\u{1E}").dropFirst() {
            let lines = chunk.split(whereSeparator: \.isNewline).map(String.init)
            if let name = lines.first { sections[name] = Array(lines.dropFirst()) }
        }
        func first(_ name: String) -> String? { sections[name]?.first?.trimmingCharacters(in: .whitespaces) }
        var s = HostStats(host: host, connected: true)
        s.os = first("os")
        s.cores = first("cores").flatMap { Int($0) }
        s.uptime = first("uptime").flatMap { Double($0) }
        // "0.32 0.29 0.32 1/499 1660156" (Linux) or "{ 1.20 1.31 1.40 }" (sysctl)
        let load = (first("load") ?? "").split(separator: " ").compactMap { Double($0) }.prefix(3)
        s.load = load.count == 3 ? Array(load) : nil
        s.cpu = cpu(sections["cpu"] ?? [])
        memory(sections["mem"] ?? [], into: &s)
        // "/dev/sda2 61806672 27830152 31338988 48% /"
        if let d = first("disk")?.split(separator: " ", omittingEmptySubsequences: true), d.count >= 4,
            let total = Int(d[1]), let used = Int(d[2])
        {
            s.diskTotal = total * 1024
            s.disk = used * 1024
        }
        s.ports = ports(sections["ports"] ?? [])
        let panes = (sections["tmux"] ?? []).compactMap { line -> (String, Int)? in
            let f = line.split(separator: " ")
            guard f.count == 2, let pid = Int(f[1]) else { return nil }
            return (String(f[0]), pid)
        }
        var seen = Set<String>()
        s.tmux = panes.map(\.0).filter { Tmux.isOwn($0) && seen.insert($0).inserted }.map {
            HostStats.TmuxSession(name: $0, session: owner[$0])
        }
        let all = (sections["ps"] ?? []).compactMap(process)
        s.processCount = all.count
        s.processes = busiest(all, panes: panes, owner: owner)
        return s
    }

    /// Two `cpu` lines of /proc/stat a moment apart: the share not idle (idle and iowait) in between.
    static func cpu(_ lines: [String]) -> Double? {
        let ticks = lines.prefix(2).map { $0.split(separator: " ").dropFirst().prefix(8).compactMap { Double($0) } }
        guard ticks.count == 2, ticks.allSatisfy({ $0.count >= 5 }) else { return nil }
        let total = ticks[1].reduce(0, +) - ticks[0].reduce(0, +)
        let idle = (ticks[1][3] + ticks[1][4]) - (ticks[0][3] + ticks[0][4])
        return total > 0 ? max(0, min(100, (total - idle) / total * 100)) : nil
    }

    private static func memory(_ lines: [String], into s: inout HostStats) {
        var kb: [String: Int] = [:]
        for l in lines {
            let f = l.split(separator: " ", omittingEmptySubsequences: true)
            if f.count >= 2, let v = Int(f[1]) { kb[String(f[0].dropLast())] = v * 1024 }
        }
        if let total = kb["MemTotal"], let free = kb["MemAvailable"] {
            s.memoryTotal = total
            s.memory = total - free
        }
        if let total = kb["SwapTotal"], let free = kb["SwapFree"] {
            s.swapTotal = total
            s.swap = total - free
        }
    }

    /// "0.0.0.0:22", "[::1]:5432", "127.0.0.53%lo:53", "*:80" (ss); "127.0.0.1.5432", "*.22" (netstat). A port open on any
    /// address isn't local.
    static func ports(_ lines: [String]) -> [HostStats.Port] {
        var local: [Int: Bool] = [:]
        for l in lines {
            let a = l.trimmingCharacters(in: .whitespaces)
            guard let cut = a.lastIndex(where: { $0 == ":" || $0 == "." }), let port = Int(a[a.index(after: cut)...])
            else { continue }
            let addr = a[..<cut]
            let here = addr.hasPrefix("127.") || addr == "[::1]" || addr == "::1" || addr == "localhost"
            local[port] = (local[port] ?? true) && here
        }
        return local.keys.sorted().map { HostStats.Port(port: $0, local: local[$0] ?? false) }
    }

    /// "  761  1 root  5.6  7388  3-10:57:50 /usr/sbin/charon --foo"
    static func process(_ line: String) -> (HostStats.Process, ppid: Int)? {
        let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard f.count == 7, let pid = Int(f[0]), let ppid = Int(f[1]), let cpu = Double(f[3]), let rss = Int(f[4])
        else { return nil }
        let args = String(f[6]).trimmingCharacters(in: .whitespaces)
        let command =
            args.hasPrefix("[")
            ? String(args.dropFirst().prefix { $0 != "]" })
            : ((args.split(separator: " ").first.map(String.init) ?? args) as NSString).lastPathComponent
                .trimmingCharacters(in: [":"])   // "sshd:"
        let p = HostStats.Process(
            pid: pid, user: String(f[2]), cpu: cpu, memory: rss * 1024, seconds: seconds(String(f[5])),
            command: command, args: String(args.prefix(300)))
        return (p, ppid)
    }

    /// ps's elapsed time, "[[dd-]hh:]mm:ss".
    static func seconds(_ etime: String) -> Int {
        let dayCut = etime.split(separator: "-", maxSplits: 1)
        let days = dayCut.count == 2 ? Int(dayCut[0]) ?? 0 : 0
        let clock = (dayCut.last ?? "").split(separator: ":").compactMap { Int($0) }
        return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    /// Every process of a Kelp session (under its tmux pane) and the 30 busiest others, busiest first.
    static func busiest(_ all: [(HostStats.Process, ppid: Int)], panes: [(String, Int)], owner: [String: String])
        -> [HostStats.Process]
    {
        var kids: [Int: [Int]] = [:]
        for (p, ppid) in all { kids[ppid, default: []].append(p.pid) }
        var whose: [Int: String] = [:]
        for (name, pane) in panes {
            guard let sid = owner[name] else { continue }
            var stack = [pane]
            while let pid = stack.popLast() {
                guard whose[pid] == nil else { continue }
                whose[pid] = sid
                stack += kids[pid] ?? []
            }
        }
        let tagged = all.map { p, _ in
            var p = p
            p.session = whose[p.pid]
            return p
        }
        let byCPU = tagged.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
        let others = byCPU.filter { $0.session == nil }.prefix(30)
        return byCPU.filter { $0.session != nil || others.contains($0) }
    }
}

extension HostStatsRead: Handled {
    func handle(_ sessions: Sessions) throws -> HostStats {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard RemoteHost.isHost(host) else {
            throw RPCError.invalidParams("Enter the host, as you'd type it after ssh.")
        }
        let all = Log.store.attempt("reading the sessions") { try sessions.store.sessions() } ?? []
        return HostStatsReader.read(
            sessions.remotes.host(host, path: "~"), connect: connect == true, sessions: all, errors: sessions.hostErrors
        )
    }
}

extension HostDisconnect: Handled {
    func handle(_ sessions: Sessions) throws -> Done {
        guard RemoteHost.isHost(host) else {
            throw RPCError.invalidParams("Enter the host, as you'd type it after ssh.")
        }
        HostStatsReader.disconnect(sessions.remotes.host(host, path: "~"), errors: sessions.hostErrors)
        return Done()
    }
}
