import Foundation
import Testing
import Core
import Agents
@testable import Daemon

/// A session whose /restart would land in `cat`, which prints it; its turn just ended with this payload.
private func finishedTurn(_ w: World, _ name: String, tasks: [JSONValue]? = nil, crons: [JSONValue]? = nil) async throws -> (Session, LiveSession) {
    let wt = try await desk(w, name)
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "stty -echo; echo ready; exec cat"))
    let ls = try #require(w.d.sessions.live[s.id])
    #expect(try await waitFor(30) { ls.startedUp })
    _ = try await w.c.call(SessionSend(id: s.id, text: "a prompt"))
    _ = try await w.c.call(SessionHook(id: s.id, event: "done", backgroundTasks: tasks, sessionCrons: crons))
    #expect(try await waitFor(10) { ls.snapshot.status == .done })
    return (s, ls)
}

/// Its turn over and nothing left to lose, the agent is restarted: once for a version, again for the next one.
@Test func anIdleAgentRestartsOncePerVersion() async throws {
    let w = try await world(); defer { w.d.stop() }
    let (s, ls) = try await finishedTurn(w, "update")
    #expect(!ls.restartAgent(into: "v2", quiet: 3600))   // not quiet for long enough
    #expect(ls.restartAgent(into: "v2", quiet: 0))
    #expect(try await waitFor(10) { try await w.c.call(SessionRead(id: s.id)).contains("/restart") })
    #expect(!ls.restartAgent(into: "v2", quiet: 0))
    #expect(ls.restartAgent(into: "v3", quiet: 0))
}

/// Quiet isn't idle: what runs in the background and the timers of a /loop would be lost with the program.
@Test func anAgentWithSomethingToWakeItIsLeftAlone() async throws {
    let w = try await world(); defer { w.d.stop() }
    let server: JSONValue = .obj(["id": "b1", "type": "shell", "status": "running", "command": "npm run dev"])
    let cron: JSONValue = .obj(["id": "c1", "schedule": "*/5 * * * *", "recurring": true, "prompt": "go on"])
    #expect(!(try await finishedTurn(w, "tasks", tasks: [server]).1.restartAgent(into: "v2", quiet: 0)))
    #expect(!(try await finishedTurn(w, "crons", crons: [cron]).1.restartAgent(into: "v2", quiet: 0)))
}

/// Any key since the last line sent: /restart would land behind what's in the box and its Return send both. ↑ puts an old
/// prompt there without a character for `typing` to see.
@Test func anAgentWithKeysInItsBoxIsLeftAlone() async throws {
    let w = try await world(); defer { w.d.stop() }
    let (s, ls) = try await finishedTurn(w, "keys")
    func keys(_ k: String) async throws {
        let before = ls.inputs
        _ = try await w.c.call(SessionWrite(id: s.id, base64: Data(k.utf8).base64EncodedString()))
        #expect(try await waitFor(5) { ls.inputs > before })
    }
    try await keys("\u{1B}[I")   // focus coming back to the tab is no key
    try await keys("\u{1B}[A")
    #expect(!ls.restartAgent(into: "v2", quiet: 0))
    try await keys("\r")
    #expect(ls.restartAgent(into: "v2", quiet: 0))
}

/// Before its first turn, while it works and while it asks, there's no moment to take.
@Test func onlyAFinishedTurnCounts() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "fresh")
    let fresh = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "exec cat"))
    let ls = try #require(w.d.sessions.live[fresh.id])
    #expect(try await waitFor(30) { ls.startedUp })
    #expect(!ls.restartAgent(into: "v2", quiet: 0))
    let (s, done) = try await finishedTurn(w, "asks")
    _ = try await w.c.call(SessionHook(id: s.id, event: "waiting"))
    #expect(try await waitFor(10) { done.snapshot.status == .waiting })
    #expect(!done.restartAgent(into: "v2", quiet: 0))
    _ = try await w.c.call(SessionHook(id: s.id, event: "working"))
    #expect(try await waitFor(10) { done.snapshot.status == .working })
    #expect(!done.restartAgent(into: "v2", quiet: 0))
}

@Test func onlyANativeInstallOnAnotherVersionIsOutdated() {
    let versions = "/Users/me/.local/share/claude/versions"
    #expect(Sessions.outdated(running: "\(versions)/2.1.314", installed: "\(versions)/2.1.315"))
    #expect(!Sessions.outdated(running: "\(versions)/2.1.314", installed: "\(versions)/2.1.314"))
    #expect(!Sessions.outdated(running: "/opt/homebrew/Caskroom/claude-code/2.1.314/claude", installed: "/opt/homebrew/Caskroom/claude-code/2.1.315/claude"))
    #expect(!Sessions.outdated(running: "/usr/bin/ssh", installed: "\(versions)/2.1.315"))
    #expect(!Sessions.outdated(running: nil, installed: "\(versions)/2.1.315"))
}
