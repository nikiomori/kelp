import Foundation
import Testing
import Core
@testable import Daemon
import TestSupport

/// Claude Code stops after each turn of a /goal and goes on until its check says met: the row says working (and the
/// goal) until the transcript has that answer, then done.
@Test func aStopWithAGoalOpenIsDoneOnlyOnceTheGoalIsMet() async throws {
    let p = try await world(); defer { p.d.stop() }
    let w = try await firstDesk(p)
    let s: Session = try await p.c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    let transcript = p.root.appendingPathComponent("\(UUID().uuidString).jsonl")
    func line(_ id: String, met: Bool) -> String {
        #"{"type":"attachment","uuid":"\#(id)","attachment":{"type":"goal_status","met":\#(met),"condition":"tests pass"}}"# + "\n"
    }
    try line("g1", met: false).write(to: transcript, atomically: true, encoding: .utf8)
    func record() async throws -> Session? { try await p.c.call("session.list", as: [Session].self).first { $0.id == s.id } }
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "working", "transcript": .string(transcript.path)]))
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "done", "transcript": .string(transcript.path)]))
    #expect(try await waitFor { try await record()?.goal == "tests pass" })
    #expect(try await record()?.status == .working)
    try (line("g1", met: false) + line("g2", met: true)).write(to: transcript, atomically: true, encoding: .utf8)
    #expect(try await waitFor(10) { try await record()?.status == .done })
    #expect(try await record()?.goal == nil)
    _ = try await p.c.call("session.kill", .obj(["id": .string(s.id)]))
}

/// A Stop while a command it started in the background runs: working, the command on the record, until it's woken.
@Test func aStopWhileItsCommandRunsIsNotDone() async throws {
    let p = try await world(); defer { p.d.stop() }
    let w = try await firstDesk(p)
    let s: Session = try await p.c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    func record() async throws -> Session? { try await p.c.call("session.list", as: [Session].self).first { $0.id == s.id } }
    let tests: JSONValue = .obj(["id": "b1", "type": "shell", "status": "running", "command": "npm test"])
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "done", "background_tasks": .array([tests])]))
    #expect(try await waitFor { try await record()?.background == ["npm test"] })
    #expect(try await record()?.status == .working)
    #expect(try await record()?.awaiting == "npm test")
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))   // the <task-notification> turn
    #expect(try await waitFor { try await record()?.awaiting == nil })
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "done", "background_tasks": .array([])]))
    #expect(try await waitFor { try await record()?.status == .done })
    #expect(try await record()?.background == nil)
    _ = try await p.c.call("session.kill", .obj(["id": .string(s.id)]))
}

/// A server left from an earlier turn is listed but never waited for; tests it sends to the background mid-turn are on
/// the record at once, as what it waits for, while it asks too.
@Test func aServerIsNotAwaitedButTestsSentToTheBackgroundAre() async throws {
    let p = try await world(); defer { p.d.stop() }
    let w = try await firstDesk(p)
    let s: Session = try await p.c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    func record() async throws -> Session? { try await p.c.call("session.list", as: [Session].self).first { $0.id == s.id } }
    func hook(_ event: String, _ tasks: [JSONValue]? = nil) async throws {
        _ = try await p.c.call(SessionHook(id: s.id, event: event, backgroundTasks: tasks))
    }
    let server: JSONValue = .obj(["id": "b1", "type": "shell", "status": "running", "command": "npm run dev"])
    try await hook("working")
    try await hook("done", [server])
    #expect(try await waitFor { try await record()?.status == .done })
    #expect(try await record()?.background == ["npm run dev"])
    #expect(try await record()?.awaiting == nil)
    try await hook("working")
    #expect(try await record()?.awaiting == nil)   // working on, not waiting for the server
    let tests = AgentCommand(id: "t1", command: "npm test", started: Date(), ended: Date(), outcome: .background)
    _ = try await p.c.call(SessionHook(id: s.id, event: "command", command: tests))
    try await hook("waiting")
    #expect(try await waitFor { try await record()?.status == .waiting })
    #expect(try await record()?.awaiting == "npm test")
    #expect(try await record()?.background == ["npm run dev", "npm test"])
    _ = try await p.c.call("session.kill", .obj(["id": .string(s.id)]))
}
