import Agents
import Core
import Foundation
import Testing

@testable import Daemon

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])
/// Half a day from now: the daemon's own clock, running beside the test, never finds it due.
private var farOff: Int { (Calendar.current.component(.hour, from: Date()) + 12) % 24 * 60 }

/// The events a client was sent, by name.
private final class Heard: @unchecked Sendable {
    private let l = NSLock()
    private var names: [String] = []
    func add(_ m: String) {
        l.lock()
        names.append(m)
        l.unlock()
    }
    var all: [String] {
        l.lock()
        defer { l.unlock() }
        return names
    }
}

/// A routine counts from when it's added; its due time runs the agent in a workspace of its own, named after it, and the
/// run follows the agent: asked, then done. A second Run Now while it runs is refused.
@Test func aRoutineRunsItsAgentAtItsTime() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let heard = Heard()
    w.c.onNotification = { m, _ in heard.add(m) }
    await #expect(throws: RPCError.self) {
        try await w.c.call(RoutineSet(routine: Routine(name: " ", repoId: w.repo.id, agent: "bot", prompt: "x")))
    }
    var r = try await w.c.call(
        RoutineSet(
            routine: Routine(
                name: "Morning triage", repoId: w.repo.id, agent: "bot", prompt: "triage", every: .daily, time: farOff))
    )
    #expect(!r.id.isEmpty)
    w.d.workspaces.routines.tick(workspaces: w.d.workspaces, now: r.checked.addingTimeInterval(1))
    #expect(try await w.c.call(RoutineList()).runs.isEmpty)   // nothing due yet

    let due = try #require(r.next(after: r.checked))
    w.d.workspaces.routines.tick(workspaces: w.d.workspaces, now: due.addingTimeInterval(5))
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
        try await waitFor {
            w.d.workspaces.routines.tick(workspaces: w.d.workspaces, now: due.addingTimeInterval(20))
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

/// A due time that can't start its agent leaves a failed run saying why, and the next routine still runs.
@Test func aRoutineThatCantStartSaysWhy() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let bad = try await w.c.call(
        RoutineSet(
            routine: Routine(
                name: "Gone", repoId: w.repo.id, agent: "uninstalled", prompt: "x", every: .daily, time: farOff)))
    let good = try await w.c.call(
        RoutineSet(
            routine: Routine(name: "Here", repoId: w.repo.id, agent: "bot", prompt: "x", every: .daily, time: farOff)))
    let due = try #require(bad.next(after: bad.checked))
    w.d.workspaces.routines.tick(workspaces: w.d.workspaces, now: due.addingTimeInterval(5))
    let runs = try await w.c.call(RoutineList()).runs
    let failed = try #require(runs.first { $0.routineId == bad.id })
    #expect(failed.outcome == .failed && failed.summary.contains("uninstalled") && failed.ended != nil)
    #expect(runs.first { $0.routineId == good.id }?.outcome == .running)
}

/// A prompt behind a dialog nobody answers leaves its agent idle: taken for a run in progress, every later one was skipped.
@Test func aRunThatNeverStartedFails() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let r = try await w.c.call(
        RoutineSet(
            routine: Routine(name: "Stuck", repoId: w.repo.id, agent: "bot", prompt: "x", every: .daily, time: farOff)))
    let due = try #require(r.next(after: r.checked))
    w.d.workspaces.routines.tick(workspaces: w.d.workspaces, now: due.addingTimeInterval(5))
    let run = try #require(try await w.c.call(RoutineList()).runs.first)
    try w.d.store.update(Routine.Run.self, run.id) {
        $0.started = Date().addingTimeInterval(-Routines.neverStartedAfter - 1)
    }
    _ = try await w.c.call(SessionAnnotate(id: try #require(run.sessionId), summary: "", status: "idle"))
    w.d.workspaces.routines.tick(workspaces: w.d.workspaces, now: due.addingTimeInterval(6))
    #expect(try await w.c.call(RoutineList()).runs.first?.outcome == .failed)
}

/// Due while the Mac slept or Kelp was off: one run when it's back, or a missed one when the routine skips those.
/// Several due times gone by make one run, not one each.
@Test func aRoutineDueWhileAwayRunsOnceOrIsMissed() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wake = try await w.c.call(
        RoutineSet(
            routine: Routine(name: "Daily", repoId: w.repo.id, agent: "bot", prompt: "x", every: .daily, time: farOff)))
    let skip = try await w.c.call(
        RoutineSet(
            routine: Routine(
                name: "Skip", repoId: w.repo.id, agent: "bot", prompt: "x", every: .daily, time: farOff,
                onWake: false)))
    let later = wake.checked.addingTimeInterval(3 * 86400)
    w.d.workspaces.routines.tick(workspaces: w.d.workspaces, now: later)
    let runs = try await w.c.call(RoutineList()).runs
    let woke = try #require(runs.first { $0.routineId == wake.id }),
        missed = try #require(runs.first { $0.routineId == skip.id })
    #expect(runs.count == 2)
    #expect(woke.outcome == .running && woke.late && woke.sessionId != nil)
    #expect(missed.outcome == .missed && missed.sessionId == nil)
    // Switched off and on again: what was due meanwhile isn't run.
    var off = skip
    off.enabled = false
    _ = try await w.c.call(RoutineSet(routine: off))
    off.enabled = true
    let on = try await w.c.call(RoutineSet(routine: off))
    #expect(on.checked > skip.checked)
}

/// An agent's routine.set asks the user on its row first, all of the routine in the question (its line breaks as
/// spaces): Deny refuses it, Allow adds it. One that can't be made, or longer than the card shows whole, isn't asked about.
@Test func anAgentsRoutineIsAddedOnlyOnceTheUserAllowsIt() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    func routine(_ name: String = "Morning triage", agent: String = "bot", prompt: String = "Label the\n  new issues.")
        -> Routine
    {
        Routine(
            name: name, repoId: w.repo.id, agent: agent, model: "fast", prompt: prompt, every: .weekly,
            time: 9 * 60 + 5, weekday: 2)
    }
    func ask(_ routine: Routine) -> Task<Routine, Error> {
        Task {
            try await Sessions.$asker.withValue(agent.id) {
                try await RoutineSet(routine: routine).handle(w.d.workspaces.routines, conn: -1)
            }
        }
    }
    func summary() throws -> String { try w.d.store.session(agent.id)?.summary ?? "" }
    let question = "Allow a routine, Morning triage: “Label the new issues.” (Bot fast, Mondays at 9:05)?"
    let denied = ask(routine())
    #expect(try await waitFor { try summary() == question })
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "deny", question: question)))
    await #expect(throws: RPCError.self) { try await denied.value }
    #expect(try await w.c.call(RoutineList()).routines.isEmpty)
    let long = String(repeating: "x", count: RoutineSet.asked.prompt + 1)
    for unasked in [routine(" "), routine(prompt: long), routine(agent: "uninstalled")] {
        await #expect(throws: RPCError.self) { try await ask(unasked).value }
    }
    #expect(try summary().isEmpty)
    let allowed = ask(routine())
    #expect(try await waitFor { try summary() == question })
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: question)))
    let added = try await allowed.value
    #expect(added.prompt == "Label the\n  new issues." && !added.id.isEmpty)   // saved as it was written
    #expect(try await w.c.call(RoutineList()).routines.map(\.id) == [added.id])
    #expect(RoutineSet.question(routine(), agent: "Bot").count < 336)   // the card's eight lines of 42
    var hourly = routine()
    (hourly.every, hourly.time, hourly.model) = (.hourly, 15, nil)
    #expect(RoutineSet.question(hourly, agent: "Bot").hasSuffix("(Bot, every hour at :15)?"))
}
