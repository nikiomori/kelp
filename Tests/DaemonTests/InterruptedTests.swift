import Agents
import Core
import Foundation
import Testing

@testable import Daemon

// Agents whose turn Kelp's going down cut short (`Session.interruptedAt`), and how they go on.

/// An agent that says how it was started, then echoes each line typed into it.
private let echo = AgentManifest(
    id: "echo6", name: "Echo", command: "/bin/zsh",
    args: ["-c", #"echo "STARTED $*"; while read -r line; do echo "GOT:$line"; done"#, "x"], resumeArgs: ["--resume"])

/// Two agents, one of them in the middle of a turn.
private func twoAgents(_ w: World) async throws -> (busy: Session, resting: Session) {
    let wt = try await workspace(w, "cut")
    func start() async throws -> Session {
        try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "echo6"]), as: Session.self)
    }
    let busy = try await start(), resting = try await start()
    for s in [busy, resting] {
        #expect(try await waitFor { try await w.c.call(SessionRead(id: s.id)).contains("STARTED") })
    }
    _ = try await w.c.call("session.hook", .obj(["id": .string(busy.id), "event": "working"]))
    #expect(try await waitFor { try w.d.store.session(busy.id)?.status == .working })
    return (busy, resting)
}

/// A daemon that stops (a restart, the Mac shutting down) marks the agents at work as cut short, unread, and only
/// those. One that crashed leaves their records saying "working", and the next daemon marks them the same way.
/// Continue wakes it with the line that has it go on, and it is no longer marked.
@Test func agentsKelpCutShortAreMarkedAndGoOnWhenContinued() async throws {
    let w = try await world(agents: [echo])
    let (busy, resting) = try await twoAgents(w)
    w.d.stop()
    let stopped = try #require(try w.d.store.session(busy.id))
    #expect(stopped.status == .paused && stopped.interruptedAt != nil && stopped.unread)
    #expect(try w.d.store.session(resting.id)?.interruptedAt == nil)
    // A crash: the record of an agent at work still says so when the next daemon starts.
    var crashed = try #require(try w.d.store.session(resting.id))
    crashed.status = .working
    _ = try w.d.store.save(crashed)
    let d = try await restarted(w.root)
    defer { d.stop() }
    let marked = try #require(try d.store.session(resting.id))
    #expect(marked.status == .paused && marked.interruptedAt != nil && marked.unread)
    let c = try client(w.root)
    _ = try await c.call(SessionSend(id: busy.id, text: Session.goOnText, enter: true))   // Continue, as the window sends it
    #expect(
        try await waitFor(30) { try await c.call(SessionRead(id: busy.id)).contains("GOT:" + Session.goOnText) })
    #expect(try d.store.session(busy.id)?.interruptedAt == nil)
    #expect(try d.store.session(resting.id)?.status == .paused)   // only the one named went on
}

/// With "Continue working agents after a crash" on, the next daemon has them go on by itself.
@Test func agentsKelpCutShortGoOnByThemselvesWithTheSetting() async throws {
    let w = try await world(agents: [echo])
    let (busy, _) = try await twoAgents(w)
    _ = try await w.c.call("settings.set", .obj(["key": .string(SettingKeys.resumeAfterCrash.key), "value": true]))
    w.d.stop()
    let d = try await restarted(w.root)
    defer { d.stop() }
    let c = try client(w.root)
    #expect(
        try await waitFor(30) { try await c.call(SessionRead(id: busy.id)).contains("GOT:" + Session.goOnText) })
}
