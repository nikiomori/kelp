import Core
import Foundation
import Testing

@testable import Daemon

/// What `host.stats` reads off a host: niko_main's real answer (Ubuntu 24.04, 2026-11-04), cut short, with one Kelp agent.
@Suite struct HostStatsTests {
    static let linux = """
        \u{1E}os
        Ubuntu 24.04.5 LTS
        \u{1E}cores
        2
        \u{1E}uptime
        298670.12
        \u{1E}load
        0.32 0.29 0.32 1/499 1660156
        \u{1E}cpu
        cpu  1537798 2098 1953108 54145249 19385 0 634509 956024 0 0
        cpu  1537800 2098 1953110 54145255 19386 0 634509 956024 0 0
        \u{1E}mem
        MemTotal:        3280752 kB
        MemAvailable:    2369756 kB
        SwapTotal:       1963004 kB
        SwapFree:        1663716 kB
        \u{1E}disk
        /dev/sda2         61806672 27830152  31338988      48% /
        \u{1E}ports
        0.0.0.0:22
        [::]:22
        127.0.0.1:5432
        127.0.0.53%lo:53
        *:80
        \u{1E}tmux
        kelp-tab-3f2a9c01 5000
        work 6000
        \u{1E}ps
            1     0 root      0.0 13000 3-10:57:50 /sbin/init
          761     1 root      5.6  7388 3-10:57:50 /usr/sbin/charon --use-syslog
         1645     2 root      1.1     0       06:45 [kworker/1:2-events]
         5000     1 niko      0.0  4000    18:02 -bash
         5001  5000 niko      1.2 219136    18:01 claude --resume
         5002  5001 niko      0.1 90112    06:00 node /usr/bin/npm run build
         6000     1 niko      0.0  4000    01:00 bash
        """

    @Test func readsALinuxHost() throws {
        let s = HostStatsReader.parse(Self.linux, host: "niko_main", owner: ["kelp-tab-3f2a9c01": "S1"])
        #expect(s.connected && s.os == "Ubuntu 24.04.5 LTS" && s.cores == 2 && s.load == [0.32, 0.29, 0.32])
        #expect(s.memoryTotal == 3280752 * 1024 && s.memory == (3280752 - 2369756) * 1024)
        #expect(s.swap == (1963004 - 1663716) * 1024 && s.diskTotal == 61806672 * 1024 && s.disk == 27830152 * 1024)
        // 11 ticks, 7 of them idle or waiting
        #expect(abs((s.cpu ?? 0) - 4.0 / 11 * 100) < 0.01)
        #expect(
            s.ports == [
                .init(port: 22, local: false), .init(port: 53, local: true), .init(port: 80, local: false),
                .init(port: 5432, local: true)
            ])
        #expect(s.tmux == [.init(name: "kelp-tab-3f2a9c01", session: "S1")])   // "work" is the user's own
        #expect(s.processCount == 7)
        let p = try #require(s.processes)
        #expect(p.first?.command == "charon" && p.first?.seconds == 3 * 86400 + 10 * 3600 + 57 * 60 + 50)
        #expect(p.first { $0.pid == 1645 }?.command == "kworker/1:2-events")
        // The agent's pane and all under it are its own; the user's tmux isn't.
        #expect(p.filter { $0.session == "S1" }.map(\.pid).sorted() == [5000, 5001, 5002])
        #expect(p.first { $0.pid == 6000 }?.session == nil)
        #expect(p.first { $0.pid == 5002 }?.command == "node")
        #expect(s.alert == nil)
    }

    /// vangerserte's answer (Debian 13 with Docker, 2026-11-13), cut short: ps with cgroups, two containers, a restart due.
    static let debian = """
        \u{1E}os
        Debian GNU/Linux 13 (trixie)
        \u{1E}cpu
        cpu  12995059 25148 4591461 642155369 429189 0 288255 6698579 0 0
        cpu  12995061 25148 4591462 642155374 429190 0 288255 6698580 0 0
        \u{1E}net
        ens3
        6633000.10   ens3: 77153549074 47200347    0    0    0     0          0         0 36752134872 63412602    0    0    0     0       0          0
        6633000.40   ens3: 77153552074 47200350    0    0    0     0          0         0 36752135772 63412605    0    0    0     0       0          0
        \u{1E}ports
        127.0.0.1:3000
        0.0.0.0:80
        0.0.0.0:22
        [::]:80
        127.0.0.1:8080 users:(("node",pid=900,fd=21))
        \u{1E}docker
        d95fb4665ed0945f06e7447b531afa9adf030b5f51347be647cd68dde858adad\tvangersert\t127.0.0.1:3000->3000/tcp
        4a7b0586bc08df1a3c62a3e4e5848b4d9f646b7c9e72eff59907b41a8947712e\tvangersert-nginx\t0.0.0.0:80->80/tcp, [::]:80->80/tcp
        \u{1E}failed
        nginx.service
        \u{1E}reboot
        yes
        \u{1E}self
        3293888
        \u{1E}psc
        1846070 1846046 1001          0.8 596752 4-21:52:58 0::/system.slice/docker-d95fb4665ed0945f06e7447b531afa9adf030b5f51347be647cd68dde858adad.scope   next-server (v15.1.0)
           3352       1 root          0.1 32600 76-17:34:15 0::/system.slice/fail2ban.service   /usr/bin/python3 /usr/bin/fail2ban-server -xf start
        1488721 1488642 dhcpcd        0.1 15356  6-11:21:18 0::/system.slice/docker-4a7b0586bc08df1a3c62a3e4e5848b4d9f646b7c9e72eff59907b41a8947712e.scope   nginx: worker process
           2888476     1 vangerserte  0.0 12084  1-08:00:00 0::/user.slice/user-1000.slice/user@1000.service/init.scope   /usr/lib/systemd/systemd --user
              8       2 root          0.0     0 76-18:36:24 -   [kworker/R-netns]
        3293888 3293880 vangerserte   0.0  1900       00:00 0::/user.slice/user-1000.slice/session-9.scope   sh -c s() {
        3293901 3293888 vangerserte   0.0  4600       00:00 0::/user.slice/user-1000.slice/session-9.scope   ps -axo pid=
        3300299 3300290 vangerserte   0.0  1800       00:00 0::/user.slice/user-1000.slice/session-9.scope   sh -c s() { printf
        3300305 3300299 vangerserte   0.0  2000       00:00 0::/user.slice/user-1000.slice/session-9.scope   sleep 0.3
        """

    @Test func readsADockerHost() throws {
        let s = HostStatsReader.parse(Self.debian, host: "vangerserte", owner: [:])
        #expect(s.os == "Debian 13 (trixie)" && s.rebootRequired == true && s.failedUnits == ["nginx.service"])
        // 10 ticks: 4 busy (1 of them stolen), 1 waiting on the disk.
        #expect(abs((s.cpu ?? 0) - 40) < 0.01 && abs((s.iowait ?? 0) - 10) < 0.01 && abs((s.steal ?? 0) - 10) < 0.01)
        let net = try #require(s.network)
        #expect(net.interface == "ens3" && abs(net.received - 10000) < 1 && abs(net.sent - 3000) < 1)
        #expect(
            s.ports == [
                .init(port: 22, local: false), .init(port: 80, local: false, container: "vangersert-nginx"),
                .init(port: 3000, local: true, container: "vangersert"), .init(port: 8080, local: true, process: "node")
            ])
        #expect(
            s.containers == [
                .init(name: "vangersert", ports: [3000], cpu: 0.8, memory: 596752 * 1024, seconds: 4 * 86400 + 78778),
                .init(name: "vangersert-nginx", ports: [80], cpu: 0.1, memory: 15356 * 1024, seconds: 6 * 86400 + 40878)
            ])
        // The reading's own shell and ps aren't listed, nor another reading going on at the same time.
        #expect(s.processCount == 5)
        let p = try #require(s.processes)
        #expect(p.first { $0.pid == 1846070 }?.container == "vangersert")
        #expect(p.first { $0.pid == 3352 }?.unit == "fail2ban.service")
        #expect(p.first { $0.pid == 2888476 }?.unit == "user@1000.service")
        #expect(p.first { $0.pid == 2888476 }?.user == "vangerserte")
        #expect(p.first { $0.pid == 8 }?.unit == nil)
    }

    @Test func unitsFromCgroups() {
        #expect(HostStatsReader.unit("0::/init.scope").unit == "init.scope")
        #expect(HostStatsReader.unit("0::/").unit == nil)
        let v1 = HostStatsReader.unit("12:pids:/docker/abc;1:name=systemd:/docker/abc")
        #expect(v1.unit == nil && v1.docker == "abc")
    }

    @Test func keepsTheLastHour() {
        let history = HostHistory(initialState: [:])
        var s = HostStats(host: "h", connected: true)
        s.cpu = 50
        let start = Date(timeIntervalSince1970: 1_000_000)
        HostStatsReader.remember(s, in: history, at: start)
        HostStatsReader.remember(s, in: history, at: start.addingTimeInterval(1800))
        HostStatsReader.remember(s, in: history, at: start.addingTimeInterval(3700))
        let kept = history.withLock { $0["h"] ?? [] }
        #expect(kept.map(\.at) == [1_001_800, 1_003_700] && kept.first?.cpu == 0.5)
    }

    @Test func saysWhatStrainsIt() {
        var s = HostStats(host: "h", connected: true)
        s.disk = 92
        s.diskTotal = 100
        #expect(s.alert?.0 == .disk && s.alert?.percent == 92)
        s.disk = 10
        s.cpu = 97
        s.cores = 2
        s.load = [0.5, 0.4, 0.3]
        #expect(s.alert == nil)   // busy just now, not for a minute
        s.load = [2.1, 1, 1]
        #expect(s.alert?.0 == .cpu && s.alert?.percent == 97)
    }

    /// The script itself, here on macOS: what Linux has only is left out, the rest comes.
    @Test func runsOnMacOS() throws {
        let out = try Subprocess.run(
            ["/bin/sh", "-c", HostStatsReader.script], cwd: NSHomeDirectory(),
            env: ProcessInfo.processInfo.environment, timeLimit: 20)
        let s = HostStatsReader.parse(String(decoding: out.stdout, as: UTF8.self), host: "mac", owner: [:])
        #expect(out.status == 0 && (s.cores ?? 0) > 0 && s.load?.count == 3 && (s.diskTotal ?? 0) > 0)
        #expect(
            (s.processCount ?? 0) > 10 && (1...30).contains(s.processes?.count ?? 0) && s.memory == nil && s.cpu == nil)
        #expect(s.os?.hasPrefix("Darwin") == true)
    }

    @Test func elapsedTimes() {
        #expect(
            HostStatsReader.seconds("06:45") == 405 && HostStatsReader.seconds("01:02:03") == 3723
                && HostStatsReader.seconds("2-00:00:01") == 172_801)
    }
}

/// A host's stats and its disconnect go to ssh only for a host: what isn't one (empty, an option, words) is refused first.
/// (Whether it reads as connected is the ssh stand-in's to say: another test may have set KELP_SSH for the process.)
@Test func onlyAHostIsAskedForItsStats() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    #expect(try await c.call(HostStatsRead(host: " nowhere.invalid ")).host == "nowhere.invalid")
    // Its history holds that one reading at most (none when it read as not connected).
    #expect(try await c.call(HostHistoryRead(host: "nowhere.invalid")).count <= 1)
    _ = try await c.call(HostDisconnect(host: "nowhere.invalid"))
    for bad in ["", "-oProxyCommand=x", "a b"] {
        await #expect(throws: (any Error).self) { _ = try await c.call(HostStatsRead(host: bad)) }
        await #expect(throws: (any Error).self) { _ = try await c.call(HostDisconnect(host: bad)) }
    }
}
