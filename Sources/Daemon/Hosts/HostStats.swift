import Core
import Foundation
import os

/// What a remote project's host is doing (`host.stats`): one `sh` over its shared connection reads /proc, df, ss, tmux
/// and ps, about 0.4 s with the connection open (0.3 of it is the CPU's two looks). Linux in full; on macOS and BSD what
/// they share (load, disk, processes).
typealias HostErrors = OSAllocatedUnfairLock<[String: String]>
/// Host → its readings of the last hour (`host.history`).
typealias HostHistory = OSAllocatedUnfairLock<[String: [HostStats.Sample]]>

enum HostStatsReader {
    /// A section a line `\036name`, so a greeting the shell prints can't pass for one.
    static let script = [
        #"s() { printf '\036%s\n' "$1"; }"#,
        // The default route's interface as /proc/net/dev counts it, after the seconds since boot.
        #"n() { [ -n "$ni" ] && echo "$(cut -d' ' -f1 /proc/uptime) $(grep "^ *$ni:" /proc/net/dev)"; }"#,
        #"s os; (. /etc/os-release && [ -n "$PRETTY_NAME" ] && echo "$PRETTY_NAME") 2>/dev/null || uname -sr"#,
        "s cores; getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null",
        "s uptime; cut -d' ' -f1 /proc/uptime 2>/dev/null",
        "s load; cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null",
        #"s cpu; if [ -r /proc/stat ]; then ni=$(awk '$2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null); n0=$(n); head -1 /proc/stat; sleep 0.3; head -1 /proc/stat; n1=$(n); fi"#,
        #"s net; [ -n "$n0" ] && printf '%s\n%s\n%s\n' "$ni" "$n0" "$n1""#,
        "s mem; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null",
        "s disk; df -kP / 2>/dev/null | tail -1",
        "s ports; if command -v ss >/dev/null 2>&1; then ss -ltnpH 2>/dev/null | awk '{print $4, $6}'; else netstat -an 2>/dev/null | awk '/LISTEN/ {print $4}'; fi",
        "s tmux; tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null",
        // A docker or systemd that hangs mustn't hold up the rest.
        #"s docker; command -v docker >/dev/null 2>&1 && timeout 2 docker ps --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null"#,
        "s failed; timeout 2 systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}'",
        "s reboot; [ -f /run/reboot-required ] && echo yes",
        // This shell, so that it and the ps it runs aren't listed. Where ps knows cgroups (Linux), the unit and container
        // of each process, and user names whole (ps cuts them at 8 letters).
        "s self; echo $$",
        "if ps -o cgroup= -p $$ >/dev/null 2>&1; then s psc; ps -axo pid=,ppid=,user:32=,pcpu=,rss=,etime=,cgroup:512=,args= 2>/dev/null",
        "else s ps; ps -axo pid=,ppid=,user=,pcpu=,rss=,etime=,args= 2>/dev/null; fi",
        "exit 0"
    ].joined(separator: "\n")

    /// `errors`: host → why its last connection failed, in ssh's words, until one works.
    static func read(
        _ remote: RemoteHost, connect: Bool, sessions: [Session], errors: HostErrors, history: HostHistory
    ) -> HostStats {
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
        let stats = parse(String(decoding: out.stdout, as: UTF8.self), host: host, owner: owner)
        remember(stats, in: history)
        return stats
    }

    /// Adds the reading to its host's last hour.
    static func remember(_ stats: HostStats, in history: HostHistory, at now: Date = Date()) {
        let at = now.timeIntervalSince1970
        let sample = HostStats.Sample(
            at: at, cpu: stats.cpu.map { $0 / 100 },
            memory: HostStats.percent(stats.memory, stats.memoryTotal).map { Double($0) / 100 },
            received: stats.network?.received, sent: stats.network?.sent)
        history.withLock { all in
            all[stats.host] = (all[stats.host] ?? []).filter { at - $0.at < 3600 } + [sample]
        }
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
        stats.os = first("os")?.replacingOccurrences(of: " GNU/Linux", with: "")
        stats.cores = first("cores").flatMap { Int($0) }
        stats.uptime = first("uptime").flatMap { Double($0) }
        // "0.32 0.29 0.32 1/499 1660156" (Linux) or "{ 1.20 1.31 1.40 }" (sysctl)
        let load = (first("load") ?? "").split(separator: " ").compactMap { Double($0) }.prefix(3)
        stats.load = load.count == 3 ? Array(load) : nil
        if let shares = cpu(sections["cpu"] ?? []) {
            (stats.cpu, stats.iowait, stats.steal) = (shares.busy, shares.iowait, shares.steal)
        }
        stats.network = network(sections["net"] ?? [])
        memory(sections["mem"] ?? [], into: &stats)
        // "/dev/sda2 61806672 27830152 31338988 48% /"
        if let columns = first("disk")?.split(separator: " ", omittingEmptySubsequences: true), columns.count >= 4,
            let total = Int(columns[1]), let used = Int(columns[2])
        {
            stats.diskTotal = total * 1024
            stats.disk = used * 1024
        }
        let docker = (sections["docker"] ?? []).compactMap(container)
        stats.ports = ports(sections["ports"] ?? []).map { port in
            var port = port
            port.container = docker.first { $0.ports.contains(port.port) }?.name
            return port
        }
        stats.failedUnits = sections["failed"].map { $0.filter { !$0.isEmpty } }
        stats.rebootRequired = first("reboot") == "yes"
        let panes = (sections["tmux"] ?? []).compactMap { line -> (String, Int)? in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let pid = Int(fields[1]) else { return nil }
            return (String(fields[0]), pid)
        }
        var seen = Set<String>()
        stats.tmux = panes.map(\.0).filter { Tmux.isOwn($0) && seen.insert($0).inserted }.map {
            HostStats.TmuxSession(name: $0, session: owner[$0])
        }
        let read =
            sections["psc"].map { $0.compactMap { process($0, cgroup: true) } }
            ?? (sections["ps"] ?? []).compactMap { process($0, cgroup: false) }
        let mine = readings(read.map { ($0.0, $0.ppid) }, me: first("self").flatMap { Int($0) })
        let all = read.filter { !mine.contains($0.0.pid) }
            .map { entry, ppid, id in
                var entry = entry
                entry.container = id.flatMap { id in docker.first { $0.id == id }?.name }
                return (entry, ppid: ppid)
            }
        stats.processCount = all.count
        stats.processes = busiest(all, panes: panes, owner: owner)
        if sections["docker"] != nil {
            stats.containers = docker.map { c in
                let mine = all.map { $0.0 }.filter { $0.container == c.name }
                return HostStats.Container(
                    name: c.name, ports: c.ports, cpu: mine.isEmpty ? nil : mine.reduce(0) { $0 + $1.cpu },
                    memory: mine.isEmpty ? nil : mine.reduce(0) { $0 + $1.memory }, seconds: mine.map(\.seconds).max())
            }
        }
        return stats
    }

    /// This reading and any other going on (the sidebar's and the server tab's can meet), with all they started: the
    /// shell running `script` (`me`, or its first line on a command line) and what's under it.
    static func readings(_ all: [(HostStats.Process, ppid: Int)], me: Int?) -> Set<Int> {
        var mine = Set(all.filter { $0.0.pid == me || $0.0.args.contains("s() { printf") }.map { $0.0.pid })
        var grew = true
        while grew {
            let more = all.filter { !mine.contains($0.0.pid) && mine.contains($0.ppid) }.map { $0.0.pid }
            mine.formUnion(more)
            grew = !more.isEmpty
        }
        return mine
    }

    /// Two `cpu` lines of /proc/stat a moment apart: the shares, 0–100, not idle (idle and iowait), waiting on the disk,
    /// and stolen in between. Columns: user nice system idle iowait irq softirq steal.
    static func cpu(_ lines: [String]) -> (busy: Double, iowait: Double, steal: Double?)? {
        let ticks = lines.prefix(2).map { $0.split(separator: " ").dropFirst().prefix(8).compactMap { Double($0) } }
        guard ticks.count == 2, ticks.allSatisfy({ $0.count >= 5 }) else { return nil }
        let total = ticks[1].reduce(0, +) - ticks[0].reduce(0, +)
        guard total > 0 else { return nil }
        func share(_ column: Int) -> Double { max(0, min(100, (ticks[1][column] - ticks[0][column]) / total * 100)) }
        let idle = (ticks[1][3] + ticks[1][4]) - (ticks[0][3] + ticks[0][4])
        let steal = ticks.allSatisfy { $0.count >= 8 } ? share(7) : nil
        return (max(0, min(100, (total - idle) / total * 100)), share(4), steal)
    }

    /// The interface, then two "<seconds since boot> <its /proc/net/dev line>" a moment apart: bytes a second in and out
    /// (the line's 1st and 9th numbers after the colon).
    static func network(_ lines: [String]) -> HostStats.Network? {
        guard lines.count == 3 else { return nil }
        let reads = lines.dropFirst().compactMap { line -> (at: Double, rx: Double, tx: Double)? in
            let halves = line.split(separator: ":", maxSplits: 1)
            guard halves.count == 2, let at = halves[0].split(separator: " ").first.flatMap({ Double($0) }) else {
                return nil
            }
            let numbers = halves[1].split(separator: " ").compactMap { Double($0) }
            return numbers.count >= 9 ? (at, numbers[0], numbers[8]) : nil
        }
        guard reads.count == 2, reads[1].at > reads[0].at else { return nil }
        let span = reads[1].at - reads[0].at
        return HostStats.Network(
            interface: lines[0], received: max(0, reads[1].rx - reads[0].rx) / span,
            sent: max(0, reads[1].tx - reads[0].tx) / span)
    }

    /// "<id>\t<name>\t0.0.0.0:80->80/tcp, [::]:80->80/tcp, 5432/tcp" (`docker ps`): the host's ports, each once.
    static func container(_ line: String) -> (id: String, name: String, ports: [Int])? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2, !fields[0].isEmpty else { return nil }
        let ports = (fields.count > 2 ? fields[2] : "").split(separator: ",").compactMap { mapping -> Int? in
            guard let arrow = mapping.range(of: "->") else { return nil }
            return mapping[..<arrow.lowerBound].split(separator: ":").last.flatMap { Int($0) }
        }
        return (String(fields[0]), String(fields[1]), Array(Set(ports)).sorted())
    }

    /// ps's cgroup, "0::/system.slice/nginx.service" (v2) or "…;1:name=systemd:/system.slice/…" (v1): the innermost
    /// systemd unit (a user's own manager rather than its init.scope), and a Docker container's id when it's in one.
    static func unit(_ cgroup: String) -> (unit: String?, docker: String?) {
        let entries = cgroup.split(separator: ";")
        let entry =
            entries.first { $0.hasPrefix("0::") } ?? entries.first { $0.contains("name=systemd") } ?? entries.first
        guard let path = entry?.split(separator: ":").last else { return (nil, nil) }
        let parts = path.split(separator: "/")
        var units = parts.filter { $0.hasSuffix(".service") || $0.hasSuffix(".scope") }.map(String.init)
        if units.count > 1, units.last == "init.scope" { units.removeLast() }
        var docker: String?
        for (index, part) in parts.enumerated() {
            if part.hasPrefix("docker-"), part.hasSuffix(".scope") {
                docker = String(part.dropFirst("docker-".count).dropLast(".scope".count))
            } else if part == "docker", index + 1 < parts.count {
                docker = String(parts[index + 1])
            }
        }
        return (units.last, docker)
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
    /// address isn't local. After it, ss's `users:(("sshd",pid=1981,fd=3))` when the process is the user's own.
    static func ports(_ lines: [String]) -> [HostStats.Port] {
        var local: [Int: Bool] = [:], process: [Int: String] = [:]
        for line in lines {
            let words = line.split(separator: " ", maxSplits: 1)
            guard let entry = words.first.map(String.init) else { continue }
            let name =
                words.count == 2
                ? words[1].components(separatedBy: "((\"").dropFirst().first?.prefix { $0 != "\"" } : nil
            guard let cut = entry.lastIndex(where: { $0 == ":" || $0 == "." }),
                let port = Int(entry[entry.index(after: cut)...])
            else { continue }
            let addr = entry[..<cut]
            let here = addr.hasPrefix("127.") || addr == "[::1]" || addr == "::1" || addr == "localhost"
            local[port] = (local[port] ?? true) && here
            if let name, !name.isEmpty { process[port] = String(name) }
        }
        return local.keys.sorted().map { HostStats.Port(port: $0, local: local[$0] ?? false, process: process[$0]) }
    }

    /// "  761  1 root  5.6  7388  3-10:57:50 /usr/sbin/charon --foo"; with `cgroup`, "0::/system.slice/x.service" before
    /// the command line. Also the id of the Docker container it's in.
    static func process(_ line: String, cgroup: Bool) -> (HostStats.Process, ppid: Int, docker: String?)? {
        let count = cgroup ? 8 : 7
        let fields = line.split(separator: " ", maxSplits: count - 1, omittingEmptySubsequences: true)
        guard fields.count == count, let pid = Int(fields[0]), let ppid = Int(fields[1]), let cpu = Double(fields[3]),
            let rss = Int(fields[4])
        else { return nil }
        let place = cgroup ? unit(String(fields[6])) : (unit: nil, docker: nil)
        let args = String(fields[count - 1]).trimmingCharacters(in: .whitespaces)
        let command =
            args.hasPrefix("[")
            ? String(args.dropFirst().prefix { $0 != "]" })
            : ((args.split(separator: " ").first.map(String.init) ?? args) as NSString).lastPathComponent
                .trimmingCharacters(in: [":"])   // "sshd:"
        let parsed = HostStats.Process(
            pid: pid, user: String(fields[2]), cpu: cpu, memory: rss * 1024, seconds: seconds(String(fields[5])),
            command: command, args: String(args.prefix(300)), unit: place.unit)
        return (parsed, ppid, place.docker)
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
            errors: processes.hostErrors, history: processes.hostHistory)
    }
}

extension HostHistoryRead: Handled {
    static var quick: Bool { true }
    func handle(_ processes: SessionProcesses) throws -> [HostStats.Sample] {
        processes.hostHistory.withLock { $0[host.trimmingCharacters(in: .whitespaces)] ?? [] }
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

extension Methods {
    static let hostStatsMethods: [any Answered.Type] = [
        HostStatsRead.self, HostHistoryRead.self, HostDisconnect.self
    ]
}
