import Foundation
import Testing
import Core
@testable import Daemon
import Agents

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])

/// The events a client was sent, by name.
private final class Heard: @unchecked Sendable {
    private let l = NSLock(); private var names: [String] = []
    func add(_ m: String) { l.lock(); names.append(m); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return names }
}

/// A routine counts from when it's added; its due time runs the agent in a workspace of its own, named after it, and the
/// run follows the agent: asked, then done. A second Run Now while it runs is refused.
@Test func aRoutineRunsItsAgentAtItsTime() async throws {
    let w = try await world(agents: [bot]); defer { w.d.stop() }
    let heard = Heard(); w.c.onNotification = { m, _ in heard.add(m) }
    await #expect(throws: RPCError.self) { try await w.c.call(RoutineSet(routine: Routine(name: " ", repoId: w.repo.id, agent: "bot", prompt: "x"))) }
    var r = try await w.c.call(RoutineSet(routine: Routine(name: "Morning triage", repoId: w.repo.id, agent: "bot", prompt: "triage", every: .daily)))
    #expect(!r.id.isEmpty)
    w.d.workspaces.routines.tick(desks: w.d.workspaces, now: r.checked.addingTimeInterval(1))
    #expect(try await w.c.call(RoutineList()).runs.isEmpty)   // nothing due yet

    let due = try #require(r.next(after: r.checked))
    w.d.workspaces.routines.tick(desks: w.d.workspaces, now: due.addingTimeInterval(5))
    let run = try #require(try await w.c.call(RoutineList()).runs.first)
    #expect(run.outcome == .running && run.due == due && !run.late)
    let sid = try #require(run.sessionId)
    let s = try #require(try w.d.store.session(sid))
    r = try #require(try await w.c.call(RoutineList()).routines.first)
    let wid = try #require(r.worktreeId)
    #expect(s.worktreeId == wid && s.agent == "bot")
    #expect(try w.d.store.worktree(wid)?.note == "Morning triage")
    #expect(try await waitFor { heard.all.contains("event.routines") })

    await #expect(throws: RPCError.self) { try await w.c.call(RoutineRun(id: r.id)) }   // it runs now
    /// The run once a tick has seen the session at `outcome`.
    func reached(_ outcome: Routine.Run.Outcome) async throws -> Routine.Run? {
        _ = try await waitFor {
            w.d.workspaces.routines.tick(desks: w.d.workspaces, now: due.addingTimeInterval(20))
            return try await w.c.call(RoutineList()).runs.first?.outcome == outcome
        }
        return try await w.c.call(RoutineList()).runs.first
    }
    _ = try await w.c.call(SessionAnnotate(id: s.id, summary: "Allow git push?", status: "waiting"))
    let asked = try #require(try await reached(.asked))
    #expect(asked.outcome == .asked && asked.summary == "Allow git push?")
    _ = try await w.c.call(SessionAnnotate(id: s.id, summary: "Triaged 4 issues", status: "done"))
    let ended = try #require(try await reached(.done))
    #expect(ended.outcome == .done && ended.ended != nil && ended.summary == "Triaged 4 issues")

    let again = try await w.c.call(RoutineRun(id: r.id))   // Run Now: the same workspace
    let againId = try #require(again.sessionId)
    #expect(try w.d.store.session(againId)?.worktreeId == wid)
    _ = try await w.c.call(RoutineDelete(id: r.id))
    let after = try await w.c.call(RoutineList())
    #expect(after.routines.isEmpty && after.runs.isEmpty)
}

/// Due while the Mac slept or Kelp was off: one run when it's back, or a missed one when the routine skips those.
/// Several due times gone by make one run, not one each.
@Test func aRoutineDueWhileAwayRunsOnceOrIsMissed() async throws {
    let w = try await world(agents: [bot]); defer { w.d.stop() }
    let wake = try await w.c.call(RoutineSet(routine: Routine(name: "Hourly", repoId: w.repo.id, agent: "bot", prompt: "x", every: .hourly)))
    let skip = try await w.c.call(RoutineSet(routine: Routine(name: "Skip", repoId: w.repo.id, agent: "bot", prompt: "x", every: .hourly, onWake: false)))
    let later = wake.checked.addingTimeInterval(5 * 3600)
    w.d.workspaces.routines.tick(desks: w.d.workspaces, now: later)
    let runs = try await w.c.call(RoutineList()).runs
    let woke = try #require(runs.first { $0.routineId == wake.id }), missed = try #require(runs.first { $0.routineId == skip.id })
    #expect(runs.count == 2)
    #expect(woke.outcome == .running && woke.late && woke.sessionId != nil)
    #expect(missed.outcome == .missed && missed.sessionId == nil)
    // Switched off and on again: what was due meanwhile isn't run.
    var off = skip; off.enabled = false
    _ = try await w.c.call(RoutineSet(routine: off))
    off.enabled = true
    let on = try await w.c.call(RoutineSet(routine: off))
    #expect(on.checked > skip.checked)
}
