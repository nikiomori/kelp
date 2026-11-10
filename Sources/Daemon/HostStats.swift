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
        let argv = [remote.ssh] + remote.sshArgs(tty: false) + ["sh -c " + ShellQuote.word(script)]
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
        let owner = Dictionary(sessions.compactMap { session in Sessions.tmuxName(session).map { ($0, session) } }) {
            first, second in
            first.status == .exited ? second : first
        }.mapValues(\.id)
        return parse(String(decoding: out.stdout, as: UTF8.self), host: host, owner: owner)
    }

    /// Closes the shared connection; what runs in tmux there goes on.
    static func disconnect(_ remote: RemoteHost, errors: HostErrors) {
        _ = Subprocess.printed(
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
        var stats = HostStats(host: host, connected: true)
        stats.os = first("os")
        stats.cores = first("cores").flatMap { Int($0) }
        stats.uptime = first("uptime").flatMap { Double($0) }
        // "0.32 0.29 0.32 1/499 1660156" (Linux) or "{ 1.20 1.31 1.40 }" (sysctl)
        let load = (first("load") ?? "").split(separator: " ").compactMap { Double($0) }.prefix(3)
        stats.load = load.count == 3 ? Array(load) : nil
        stats.cpu = cpu(sections["cpu"] ?? [])
        memory(sections["mem"] ?? [], into: &stats)
        // "/dev/sda2 61806672 27830152 31338988 48% /"
        if let columns = first("disk")?.split(separator: " ", omittingEmptySubsequences: true), columns.count >= 4,
            let total = Int(columns[1]), let used = Int(columns[2])
        {
            stats.diskTotal = total * 1024
            stats.disk = used * 1024
        }
        stats.ports = ports(sections["ports"] ?? [])
        let panes = (sections["tmux"] ?? []).compactMap { line -> (String, Int)? in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let pid = Int(fields[1]) else { return nil }
            return (String(fields[0]), pid)
        }
        var seen = Set<String>()
        stats.tmux = panes.map(\.0).filter { Tmux.isOwn($0) && seen.insert($0).inserted }.map {
            HostStats.TmuxSession(name: $0, session: owner[$0])
        }
        let all = (sections["ps"] ?? []).compactMap(process)
        stats.processCount = all.count
        stats.processes = busiest(all, panes: panes, owner: owner)
        return stats
    }

    /// Two `cpu` lines of /proc/stat a moment apart: the share not idle (idle and iowait) in between.
    static func cpu(_ lines: [String]) -> Double? {
        let ticks = lines.prefix(2).map { $0.split(separator: " ").dropFirst().prefix(8).compactMap { Double($0) } }
        guard ticks.count == 2, ticks.allSatisfy({ $0.count >= 5 }) else { return nil }
        let total = ticks[1].reduce(0, +) - ticks[0].reduce(0, +)
        let idle = (ticks[1][3] + ticks[1][4]) - (ticks[0][3] + ticks[0][4])
        return total > 0 ? max(0, min(100, (total - idle) / total * 100)) : nil
    }

    private static func memory(_ lines: [String], into stats: inout HostStats) {
        var kb: [String: Int] = [:]
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2, let kilobytes = Int(fields[1]) { kb[String(fields[0].dropLast())] = kilobytes * 1024 }
        }
        if let total = kb["MemTotal"], let free = kb["MemAvailable"] {
            stats.memoryTotal = total
            stats.memory = total - free
        }
        if let total = kb["SwapTotal"], let free = kb["SwapFree"] {
            stats.swapTotal = total
            stats.swap = total - free
        }
    }

    /// "0.0.0.0:22", "[::1]:5432", "127.0.0.53%lo:53", "*:80" (ss); "127.0.0.1.5432", "*.22" (netstat). A port open on any
    /// address isn't local.
    static func ports(_ lines: [String]) -> [HostStats.Port] {
        var local: [Int: Bool] = [:]
        for line in lines {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard let cut = entry.lastIndex(where: { $0 == ":" || $0 == "." }),
                let port = Int(entry[entry.index(after: cut)...])
            else { continue }
            let addr = entry[..<cut]
            let here = addr.hasPrefix("127.") || addr == "[::1]" || addr == "::1" || addr == "localhost"
            local[port] = (local[port] ?? true) && here
        }
        return local.keys.sorted().map { HostStats.Port(port: $0, local: local[$0] ?? false) }
    }

    /// "  761  1 root  5.6  7388  3-10:57:50 /usr/sbin/charon --foo"
    static func process(_ line: String) -> (HostStats.Process, ppid: Int)? {
        let fields = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard fields.count == 7, let pid = Int(fields[0]), let ppid = Int(fields[1]), let cpu = Double(fields[3]),
            let rss = Int(fields[4])
        else { return nil }
        let args = String(fields[6]).trimmingCharacters(in: .whitespaces)
        let command =
            args.hasPrefix("[")
            ? String(args.dropFirst().prefix { $0 != "]" })
            : ((args.split(separator: " ").first.map(String.init) ?? args) as NSString).lastPathComponent
                .trimmingCharacters(in: [":"])   // "sshd:"
        let parsed = HostStats.Process(
            pid: pid, user: String(fields[2]), cpu: cpu, memory: rss * 1024, seconds: seconds(String(fields[5])),
            command: command, args: String(args.prefix(300)))
        return (parsed, ppid)
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
        for (entry, ppid) in all { kids[ppid, default: []].append(entry.pid) }
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
        let tagged = all.map { entry, _ in
            var entry = entry
            entry.session = whose[entry.pid]
            return entry
        }
        let byCPU = tagged.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
        let others = byCPU.filter { $0.session == nil }.prefix(30)
        return byCPU.filter { $0.session != nil || others.contains($0) }
    }
}

extension HostStatsRead: Handled {
    func handle(_ processes: SessionProcesses) throws -> HostStats {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard RemoteHost.isHost(host) else {
            throw RPCError.invalidParams("Enter the host, as you'd type it after ssh.")
        }
        let all = Log.store.attempt("reading the sessions") { try processes.store.sessions() } ?? []
        return HostStatsReader.read(
            processes.remotes.host(host, path: "~"), connect: connect == true, sessions: all,
            errors: processes.hostErrors)
    }
}

extension HostDisconnect: Handled {
    func handle(_ processes: SessionProcesses) throws -> Done {
        guard RemoteHost.isHost(host) else {
            throw RPCError.invalidParams("Enter the host, as you'd type it after ssh.")
        }
        HostStatsReader.disconnect(processes.remotes.host(host, path: "~"), errors: processes.hostErrors)
        return Done()
    }
}
