import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// The 0.5 s ticker passes over a session at rest (started up, idle, nothing waiting to be typed or timed): only one
/// with something to do is ticked.
@Test func theTickerPassesOverASessionAtRest() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let workspace = try #require(try await w.c.call(WorktreeList(repoId: w.repo.id)).first)
    let s = try await w.c.call(SessionCreate(worktreeId: workspace.id, command: "cat"))   // prints nothing: idle
    let ls = try #require(w.d.sessions.existing(s.id))
    #expect(ls.tick())   // starting up: the wait for it to draw and go quiet runs on the tick
    #expect(try await waitFor(10) { w.d.sessions.tick() == 0 })   // started up and idle: nothing to do
    ls.state.withLock { $0.pendingPrompts.append(("hello", true, false)) }   // text to type once it's ready
    #expect(w.d.sessions.tick() == 1)
}

/// The idle pause counts in minutes: the ticker looks for idle agents every 15 s, not each 0.5 s round, and an agent
/// idle past the setting is paused from the tick itself (its clock moved, not waited out).
@Test func theTickerLooksForIdleAgentsEveryFifteenSeconds() async throws {
    let w = try await world(agents: [
        AgentManifest(
            id: "sleepy", name: "Sleepy", command: "/bin/sh", args: ["-c", "echo up; sleep 30"],
            resumeArgs: ["--resume"])
    ])
    defer { w.d.stop() }
    let at = Date() + 3600
    #expect(w.d.sessions.idleCheckDue(at))
    #expect(!w.d.sessions.idleCheckDue(at + 0.5) && !w.d.sessions.idleCheckDue(at + 14))
    #expect(w.d.sessions.idleCheckDue(at + 15))
    // A pause after seconds (a test's 0.03 min) is looked for each round, not 15 s late.
    #expect(w.d.sessions.idleCheckDue(at + 15.5, every: 0.45))
    let workspace = try #require(try await w.c.call(WorktreeList(repoId: w.repo.id)).first)
    let s = try await w.c.call(SessionCreate(worktreeId: workspace.id, agent: "sleepy"))
    _ = try w.d.sessions.settings.set(SettingKeys.hibernateMinutes.key, .double(1))
    #expect(
        try await waitFor(15) {
            w.d.sessions.pausingIdle.withLock { $0.lookedAt = .distantPast }   // each try a round that looks
            w.d.sessions.tick(now: at + 3600)
            return try w.d.store.session(s.id)?.status == .paused
        })
}
