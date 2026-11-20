import AgentData
import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// Codex's limits come from its app server, asked over a terminal (with its input closed it quits before answering);
/// the questions the terminal echoes back aren't taken for the answer.
@Test func codexLimitsComeFromItsAppServer() throws {
    let fake = tmp().appendingPathComponent("codex")
    try """
    #!/bin/bash
    [ "$1" = app-server ] || exit 1
    while IFS= read -r l; do
      case "$l" in *'"id":2'*) echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":14,"resetsAt":1792715745},"secondary":{"usedPercent":2}}}}';; esac
    done
    """.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let l = try #require(AgentUsage.codexLimits(path: fake.path))
    #expect(
        l.primaryUsedPercent == 14 && l.primaryResetsAt == Date(timeIntervalSince1970: 1_792_715_745)
            && l.secondaryUsedPercent == 2)
}

/// The app server's reading is the default account's: when the default logged none, it comes first and a profile's
/// reading stays (it used to take the profile's place).
@Test func codexAppServerLimitsAreTheDefaultAccounts() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let home = tmp(), work = tmp(), day = work.appendingPathComponent("sessions/2026/10/20")
    d.agentUsage.conversations.homes.withLock {
        $0 = (home.appendingPathComponent("projects"), home.appendingPathComponent("sessions"))
    }
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try
        #"{"timestamp":"2026-10-20T00:00:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":80}}}}"#
        .write(to: day.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)
    _ = try await c.call(SettingsSet(key: "usage.readPlans", value: .bool(false)))   // no real probe
    _ = try await c.call(
        SettingsSet(
            key: "accounts.profiles",
            value: .array([.obj(["name": "work", "agent": "codex", "dir": .string(work.path)])])))
    d.agentUsage.codexLive.withLock {
        $0.limits = CodexUsage.limits(rateLimits: ["primary": ["usedPercent": 14]], at: Date())
    }
    #expect(try await c.call(UsageGet(force: true)).codex.map(\.primaryUsedPercent) == [14, 80])
}

/// Cursor's Free plan reads "Included 0% used" after its last request: a session's "hit your usage limit" holds 100% until the cycle moves on.
@Test func aPlanHitHoldsOverTheProbeUntilItsCycleEnds() throws {
    let usage = { (resets: String) in
        LimitScreens.parseCursorUsage("Usage • Free   Resets \(resets)\nIncluded   0% used\nAuto   0% used")
    }
    var s = AgentUsage.PlanState()
    s.hits = [
        try #require(
            LimitScreens.parseCursorLimitHit("You've hit your usage limit … your monthly cycle ends on 11/23/2026."))
    ]
    s.read(usage("Nov 23"))
    #expect(s.readings.map(\.percent) == [100, 0])
    s.read(usage("Dec 23"))
    #expect(s.readings.map(\.percent) == [0, 0] && s.hits.isEmpty)
}

/// A probe still running when the daemon stops ends with it, even an agent that ignores the hangup: after `exit` its own
/// `defer` never runs, and a probe's Grok left on the dead terminal spun a core for a day.
@Test func aRunningUsageProbeEndsWithTheDaemon() async throws {
    let open = OpenProbes(), pidFile = tmp().path + "-pid"
    let probe = AgentUsage.PlanProbe(
        agent: "grok", command: "grok", every: 1800, ready: { $0.contains("never") }, parse: { _ in [] })
    let argv = ["/bin/bash", "-c", "trap '' HUP TERM; echo $$ > \(pidFile); while :; do sleep 0.1; done"]
    Thread.detachNewThread { _ = AgentUsage.probe(probe, argv: argv, cwd: tmp().path, open: open) }
    let readPid = {
        (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap {
            Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    #expect(try await waitFor(5) { readPid() != nil })
    let pid = try #require(readPid())
    Sessions.waitGone(open.endAll())
    // waitGone gives up at 10 s; under TSan on a shared runner the reaping can take longer
    #expect(try await waitFor(30) { kill(pid, 0) != 0 })
}

/// Only agents with a session lately have their limits read: an installed one never used isn't launched every half hour,
/// and one used stays read for two weeks after the store forgot its session.
@Test func onlyAgentsUsedLatelyAreProbed() throws {
    let (d, _, _) = try daemon()
    defer { d.stop() }
    let u = d.agentUsage
    #expect(u.readUsedLately().isEmpty)
    let s = Session(cwd: "/tmp", command: "grok", agent: "grok", status: .exited)
    try d.store.save(s)
    #expect(u.readUsedLately() == ["grok"])
    try d.store.delete(s)   // pruned: the mark remembers it
    #expect(u.readUsedLately() == ["grok"])
    #expect(u.readUsedLately(now: Date() + AgentUsage.probeLately + 3600).isEmpty)
}

/// The limits are asked every 10 s; which agents ran lately is read from the store at most once an hour.
@Test func whichAgentsRanLatelyIsReadHourly() throws {
    let (d, _, _) = try daemon()
    defer { d.stop() }
    let u = d.agentUsage, now = Date()
    #expect(u.usedLately(now: now).isEmpty)
    try d.store.save(Session(cwd: "/tmp", command: "grok", agent: "grok", status: .exited))
    #expect(u.usedLately(now: now + 60).isEmpty)
    #expect(u.usedLately(now: now + 3601) == ["grok"])
}

/// An agent nobody uses is read every 25 minutes, not every 10: a turn since the reading, one going on, or a limit
/// that reset since bring it back to its own clock.
@Test func anAgentNobodyUsesIsProbedLessOften() throws {
    let now = Date(), read = now.addingTimeInterval(-700)
    var idle = AgentUsage.PlanState(at: read, readAt: read)
    #expect(!idle.due(every: 600, now: now))
    #expect(idle.due(every: 600, now: now.addingTimeInterval(AgentUsage.idleEvery)))
    var used = idle
    used.usedAt = now.addingTimeInterval(-60)
    #expect(used.due(every: 600, now: now))
    var working = idle
    working.usedAt = read.addingTimeInterval(-60)
    working.working = true
    #expect(working.due(every: 600, now: now))
    idle.readings = [.init(kind: "session", percent: 90, resets: "in 5m")]   // reset 5 minutes after the reading
    #expect(idle.due(every: 600, now: now))
}
