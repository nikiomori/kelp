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
