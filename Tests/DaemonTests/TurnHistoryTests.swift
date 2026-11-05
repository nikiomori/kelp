import Foundation
import Testing
import Core
import GitKit
import Agents
@testable import Daemon

/// Each turn is kept, named by the prompt that started it, and any one of them reads as its own diff: up to where the
/// next one began.
@Test func everyTurnIsKeptAndReadsAsItsOwnDiff() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")]); defer { w.d.stop() }
    let wt = try await desk(w, "history")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    let live = try #require(w.d.sessions.existing(s.id))
    func turn(_ prompt: String, writes file: String) async throws {
        _ = try await w.c.call(SessionSend(id: s.id, text: prompt, enter: true))   // typed once the program is ready
        #expect(try await waitFor(5) { try await w.c.call("session.read", .obj(["id": .string(s.id)])).string?.contains(prompt) == true })
        live.noteTurn(.working)
        #expect(try await waitFor(5) { try await w.c.call(SessionTurns(id: s.id)).first?.prompt == prompt })
        try "\(prompt)\n".write(toFile: wt.path + "/" + file, atomically: true, encoding: .utf8)
        live.noteTurn(.idle)
    }
    try await turn("write the first file", writes: "one.txt")
    try await turn("now the second one", writes: "two.txt")
    let marks = try await w.c.call(SessionTurns(id: s.id))
    #expect(marks.map(\.prompt) == ["now the second one", "write the first file"])
    var first = GitDiff(id: wt.id, source: "turn", session: s.id); first.turn = marks[1].id
    #expect(try await w.c.call(first).map(\.path) == ["one.txt"])   // not the second turn's file
    var last = GitDiff(id: wt.id, source: "turn", session: s.id); last.turn = marks[0].id
    #expect(try await w.c.call(last).map(\.path) == ["two.txt"])
    #expect(try Git.run(["log", "--all", "--oneline"], cwd: wt.path).split(separator: "\n").count == 1)   // nothing in the project's history
}

/// A turn undone puts its folder back as the turn found it: after a look at what goes, only while nothing changed since
/// the look, with .env files left alone, and never past a commit or beside another agent in the folder.
@Test func aTurnIsUndoneOnlyAsPreviewed() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")]); defer { w.d.stop() }
    let wt = try await desk(w, "undo")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    let live = try #require(w.d.sessions.existing(s.id))
    let file = { (name: String) in try? String(contentsOfFile: wt.path + "/" + name, encoding: .utf8) }
    let before = file("a.txt")
    live.noteTurn(.working)
    let turn = try #require(try await waitFor(5) { !(try await w.c.call(SessionTurns(id: s.id))).isEmpty } ? try await w.c.call(SessionTurns(id: s.id)).first : nil)
    try "agent's\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    try "made\n".write(toFile: wt.path + "/new.txt", atomically: true, encoding: .utf8)
    try "KEY=1\n".write(toFile: wt.path + "/.env", atomically: true, encoding: .utf8)
    try Git.run(["add", "new.txt"], cwd: wt.path)   // the agent staged its new file
    live.noteTurn(.idle)
    let plan = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id))
    #expect(plan.files.sorted() == ["a.txt", "new.txt"])   // .env stays out
    try "later\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)   // changed after the look
    await #expect(throws: (any Error).self) { try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id, apply: true, state: plan.state)) }
    #expect(file("a.txt") == "later\n" && file("new.txt") == "made\n")
    let fresh = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id))
    _ = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id, apply: true, state: fresh.state))
    #expect(file("a.txt") == before && file("new.txt") == nil && file(".env") == "KEY=1\n")
    #expect(try Git.run(["diff", "--cached", "--name-only"], cwd: wt.path).isEmpty)   // nothing of the turn left to commit
    // Another agent in the folder, or a commit since: no.
    let other: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    await #expect(throws: (any Error).self) { try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id)) }
    _ = try await w.c.call("session.kill", .obj(["id": .string(other.id)]))
    #expect(try await waitFor(5) { w.d.sessions.existing(other.id)?.snapshot.status ?? .exited == .exited })
    try Git.run(["commit", "-q", "--allow-empty", "-m", "moved on"], cwd: wt.path)
    await #expect(throws: (any Error).self) { try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id)) }
}

/// An agent that worked from a subfolder: its turn is undone across the checkout, paths counted from the top.
@Test func aTurnFromASubfolderIsUndoneFromTheTop() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")]); defer { w.d.stop() }
    let wt = try await desk(w, "sub")
    try FileManager.default.createDirectory(atPath: wt.path + "/pkg", withIntermediateDirectories: true)
    try "pkg\n".write(toFile: wt.path + "/pkg/p.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "pkg"], cwd: wt.path); try Git.run(["commit", "-qm", "pkg"], cwd: wt.path)
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like",
                                                                "cwd": .string(wt.path + "/pkg")]), as: Session.self)
    let live = try #require(w.d.sessions.existing(s.id))
    live.noteTurn(.working)
    #expect(try await waitFor(5) { !(try await w.c.call(SessionTurns(id: s.id))).isEmpty })
    let turn = try #require(try await w.c.call(SessionTurns(id: s.id)).first)
    try "changed\n".write(toFile: wt.path + "/pkg/p.txt", atomically: true, encoding: .utf8)
    try "top\n".write(toFile: wt.path + "/top.txt", atomically: true, encoding: .utf8)
    live.noteTurn(.idle)
    let plan = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id))
    #expect(plan.files.sorted() == ["pkg/p.txt", "top.txt"])
    _ = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id, apply: true, state: plan.state))
    #expect(try String(contentsOfFile: wt.path + "/pkg/p.txt", encoding: .utf8) == "pkg\n")
    #expect(!FileManager.default.fileExists(atPath: wt.path + "/top.txt"))
}

/// A session sees its folder's ports in KELP_PORT.
@Test func aSessionKnowsItsFoldersPorts() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "ports")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "command": "echo port=$KELP_PORT; sleep 5"]), as: Session.self)
    let want = PortBlocks.port(for: wt.path, among: try w.d.store.worktrees().map(\.path))
    #expect(try await waitFor(5) { try await w.c.call("session.read", .obj(["id": .string(s.id)])).string?.contains("port=\(want)") == true })
}

/// With a folder for worktrees set, a branch's worktree goes there, in a subfolder named after the project.
@Test func worktreesGoToTheChosenFolder() async throws {
    let w = try await world(); defer { w.d.stop() }
    let chosen = tmp().path
    _ = try w.d.settings.set("worktrees.folder", .string(chosen))
    let wt: Worktree = try await w.c.call("worktree.create", .obj(["repoId": .string(w.repo.id), "branch": "feat/here", "setup": false]),
                                          as: Worktree.self)
    let name = Git.slug(w.repo.name).replacingOccurrences(of: ".", with: "-")
    #expect(URL(fileURLWithPath: wt.path).resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: chosen + "/" + name).resolvingSymlinksInPath().path))
}

/// Working with no news for five minutes is said as quiet since the last news; news, or another status, ends it.
@Test func aWorkingAgentWithNoNewsIsQuiet() {
    var s = LiveSession.State(record: Session(cwd: "/", command: "x"), manifest: AgentManifest(id: "x", name: "x", command: "x"),
                              logSize: 0, callbacks: .init(), trail: .init(history: tmp(), session: "q"))
    let now = Date(), then = now.addingTimeInterval(-600)
    s.record.status = .working
    s.record.statusAt = then
    s.lastOutputAt = now.addingTimeInterval(-60)
    var changed = s.noteQuiet(now: now)
    #expect(!changed && s.record.quietSince == nil)   // a minute: not yet
    s.lastOutputAt = then
    changed = s.noteQuiet(now: now)
    #expect(changed && s.record.quietSince == then)
    changed = s.noteQuiet(now: now)
    #expect(!changed)   // said once
    s.lastOutputAt = now
    changed = s.noteQuiet(now: now)
    #expect(changed && s.record.quietSince == nil)
}

/// A new branch given a name is named after it, "-2" when that's taken.
@Test func aNewBranchIsNamedAfterTheNameGiven() async throws {
    let w = try await world(); defer { w.d.stop() }
    let first: WorktreeCreate.Result = try await w.c.call(WorktreeCreate(repoId: w.repo.id, note: "Fix the login page", setup: false))
    #expect(first.worktree.branch.hasSuffix("login-page") && first.worktree.note == "Fix the login page")
    let again: WorktreeCreate.Result = try await w.c.call(WorktreeCreate(repoId: w.repo.id, note: "Fix the login page", setup: false))
    #expect(again.worktree.branch == first.worktree.branch + "-2")
}

/// Allow given in Kelp goes to the question's waiting hook, not into the menu; once it's answered otherwise, the hook
/// goes with no answer.
@Test func allowGoesToTheWaitingHook() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")]); defer { w.d.stop() }
    let wt = try await desk(w, "perm")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    let c = w.c, id = s.id
    let waiting = Task { try await c.call(SessionPermissionWait(id: id)) }
    #expect(try await waitFor(5) { w.d.sessions.permissionWaits.withLock { $0[id] != nil } })
    #expect(try await c.call(SessionChoose(id: id, answer: "allow")))
    #expect(try await waiting.value == "allow")
    #expect(w.d.sessions.existing(id)?.snapshot.status == .working)
    let again = Task { try await c.call(SessionPermissionWait(id: id)) }
    #expect(try await waitFor(5) { w.d.sessions.permissionWaits.withLock { $0[id] != nil } })
    w.d.sessions.answerPermission(id, nil)   // as when it's answered in the terminal and stops waiting
    #expect(try await again.value == nil)
    // A banner left from an earlier question doesn't answer the one whose hook waits now.
    let third = Task { try await c.call(SessionPermissionWait(id: id)) }
    #expect(try await waitFor(5) { w.d.sessions.permissionWaits.withLock { $0[id] != nil } })
    let ls = try #require(w.d.sessions.existing(id))
    ls.hook("waiting", message: "Allow git push --force?", asker: "")
    #expect(try await c.call(SessionChoose(id: id, answer: "allow", question: "Allow ls?")) == false)
    #expect(w.d.sessions.permissionWaits.withLock { $0[id] != nil })
    #expect(try await c.call(SessionChoose(id: id, answer: "deny", question: "Allow git push --force?")))
    #expect(try await third.value == "deny")
    #expect(Hooks.settingsJSON().contains(#""PermissionRequest":[{"hooks":[{"type":"command","command":"kelp hook waiting","timeout":610}]}]"#))
}

/// A recap is asked only of Claude Code with a conversation to fork; any other session gets none and keeps its summary.
@Test func aRecapIsOnlyForClaudeCode() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")]); defer { w.d.stop() }
    let wt = try await desk(w, "recap")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    #expect(try await w.c.call(SessionRecap(id: s.id)) == nil)
    #expect(try await w.c.call(SessionRecap(id: "gone")) == nil)
    #expect(SessionRecap.prompt.contains("what is left"))
}
