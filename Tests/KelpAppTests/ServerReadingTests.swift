import Core
import Foundation
import Testing

@testable import BuiltinServers

/// A server's readings as its header, card and tab say them: a used amount in its total's unit, a rate, ps's percent,
/// the load averages, and orange from 90 %.
@Test func aServersReadingsAreSaidInTheirTotalsUnit() {
    let gib = 1 << 30, mib = 1 << 20
    for (n, total, said) in [
        (gib - 10 * mib, 2 * gib, "0.99 GB"), (512 * mib, 4 * gib, "0.50 GB"), (300 * mib, 900 * mib, "300.0 MB"),
        (2 << 40, 4 << 40, "2.00 TB"), (2048, 1 << 10, "2 KB")
    ] {
        #expect(ServerReading.amount(n, like: total) == said, "\(n) of \(total)")
    }
    #expect(ServerReading.used(nil, 100) == nil && ServerReading.used(5, 0) == nil)   // without both, nothing
    #expect(ServerReading.rate(999.4) == "999 B/s" && ServerReading.rate(14_000).hasSuffix("/s"))
    #expect(ServerReading.percent(0.42) == "0.4%")
    var stats = HostStats(host: "box", connected: true)
    #expect(ServerReading.load(stats) == nil)
    stats.load = [0.523, 0.4, 0.31]
    #expect(
        ServerReading.load(stats) == "0.52 0.40 0.31"
            && ServerReading.load(stats, separator: ", ") == "0.52, 0.40, 0.31")
    #expect(!ServerReading.strained(0.89) && ServerReading.strained(0.9))
}

/// A process's row: what follows its program on the command line (nothing for a kernel thread), and what it's part of —
/// its container first, else its systemd unit, a login's scope by that name.
@Test func aServersProcessSaysItsArgumentsAndWhereItRuns() {
    func process(_ args: String, unit: String? = nil, container: String? = nil) -> HostStats.Process {
        HostStats.Process(
            pid: 1, user: "root", cpu: 0, memory: 0, seconds: 0, command: "x", args: args, unit: unit,
            container: container)
    }
    for (args, rest) in [
        ("nginx: worker process", "worker process"), ("[kworker/0:1]", ""), ("/usr/bin/sleep", ""),
        ("/usr/bin/fail2ban-server -xf start", "-xf start")
    ] {
        #expect(ServerReading.arguments(process(args)) == rest, "\(args)")
    }
    for (unit, container, place) in [
        ("nginx.service", nil, "gearshape nginx"), ("session-4.scope", nil, "terminal Login session"),
        ("user@1000.scope", nil, "gearshape user@1000"), ("cron", nil, "gearshape cron"),
        ("docker.service", "web", "shippingbox web"), (nil, nil, nil)
    ] as [(String?, String?, String?)] {
        let found = ServerReading.place(process("x", unit: unit, container: container))
        #expect(found.map { "\($0.symbol) \($0.name)" } == place, "\(unit ?? "-") \(container ?? "-")")
    }
}

/// A server's line under its name and the tooltip: what it runs, or why there's nothing to say.
@MainActor @Test func aServersLineSaysWhatItRunsOrWhyNot() throws {
    #expect(serverLine(nil) == "Reading…")
    var stats = HostStats(host: "box", connected: false)
    #expect(serverLine(stats) == "Not connected. Opening it connects.")
    #expect(ServerHeader.details(stats) == "Not connected. Click to open the server, which connects.")
    stats.error = "Connection refused"
    #expect(
        serverLine(stats) == "Can't reach: Connection refused" && ServerHeader.details(stats) == "Connection refused")
    stats = HostStats(host: "box", connected: true)
    (stats.os, stats.cores) = ("Ubuntu 24.04", 1)
    #expect(serverLine(stats) == "Ubuntu 24.04 · 1 core")
    (stats.cpu, stats.load, stats.memory, stats.memoryTotal) = (12.4, [0.5, 0.4, 0.3], 1 << 30, 4 << 30)
    let lines = try #require(ServerHeader.details(stats)?.split(separator: "\n").map(String.init))
    try #require(lines.count == 3, "\(lines)")
    #expect(lines[1] == "CPU 12% · load 0.50 0.40 0.30")
    #expect(lines[2].hasPrefix("Memory ") && lines[2].hasSuffix(" · 25%"), "\(lines[2])")
}

/// The processes' table sorts by the column its header names, the other way on a second click, and rows that are
/// equal by that column keep one order from reading to reading, whatever order the reading came in (so rows at 0.0 %
/// don't trade places under a chosen row). One program's processes in one place are one line.
@Test func aServersProcessesSortBothWaysAndKeepTheirPlaces() {
    func process(_ pid: Int, _ command: String, cpu: Double, mb: Int = 1, container: String? = nil) -> HostStats.Process
    {
        HostStats.Process(
            pid: pid, user: "root", cpu: cpu, memory: mb << 20, seconds: pid, command: command, args: command,
            container: container)
    }
    let read = [
        process(1, "nginx", cpu: 0, container: "web"), process(2, "nginx", cpu: 2, container: "web"),
        process(3, "sshd", cpu: 5), process(4, "cron", cpu: 0), process(5, "atd", cpu: 0),
        process(6, "nginx", cpu: 1, container: "proxy")
    ]
    func names(_ by: ServerProcesses.Sort, up: Bool, _ processes: [HostStats.Process]) -> [String] {
        ServerProcesses.lines(processes, kelpOnly: false, order: .init(by: by, ascending: up)).map {
            "\($0.members[0].command)\($0.members[0].container.map { "@" + $0 } ?? "")×\($0.members.count)"
        }
    }
    let busiest = names(.cpu, up: false, read)
    #expect(busiest.prefix(3) == ["sshd×1", "nginx@web×2", "nginx@proxy×1"])
    #expect(names(.cpu, up: true, read).suffix(3) == ["nginx@proxy×1", "nginx@web×2", "sshd×1"])
    #expect(names(.command, up: true, read).first == "atd×1" && names(.command, up: false, read).first == "sshd×1")
    // cron and atd both stand at 0 %: the same order whichever way the reading lists them.
    #expect(names(.cpu, up: false, read.reversed()) == busiest && names(.cpu, up: false, read.shuffled()) == busiest)
    #expect(ServerProcesses.lines(read, kelpOnly: true, order: .init(by: .cpu, ascending: false)).isEmpty)
}
