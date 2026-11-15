import Core
import Foundation
import Testing

@testable import Daemon

// The rest of the agent rules' table (`whoMayDoWhat`): what acts on a workspace or a session, a caller whose session is
// gone, and how many of the methods agents may call still have no row.

/// What acts on a workspace is held to the agent's own; a remote op there is a fetch, never a push; a session the user
/// started isn't the agent's to mark, while its own terminal's size it may set, as an attach does.
@Test func whoMayActOnWorkspacesAndSessions() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "feat/x")
    let term: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "command": "cat"]), as: Session.self)
    var mine = Session(worktreeId: wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    mine.origin = Caller.typedAgent(term.id).origin
    var theirs = Session(worktreeId: wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    theirs.origin = term.id
    let elsewhere = Worktree(repoId: w.repo.id, branch: "o", path: "/tmp/o")
    try w.d.sessions.store.save(mine)
    try w.d.sessions.store.save(theirs)
    try w.d.sessions.store.save(elsewhere)
    let typed = Caller.typedAgent(term.id)
    let table: [(Caller, any Answered, Bool, String)] = [
        (.session(mine.id), WorktreeRemove(id: elsewhere.id), false, "it doesn't remove another's workspace"),
        (.session(mine.id), WorktreeArchive(id: elsewhere.id), false, "nor archive it"),
        (.session(mine.id), GitRemoteOp(id: elsewhere.id, op: "fetch"), false, "nor fetch there"),
        (.session(mine.id), GitRemoteOp(id: wt.id, op: "fetch"), true, "in its own it fetches"),
        (.session(mine.id), GitRemoteOp(id: wt.id, op: "push"), false, "but never pushes"),
        (typed, SessionMarkRead(id: theirs.id), false, "nor marks read what the user started"),
        (typed, SessionResize(id: term.id, cols: 80, rows: 24), true, "its terminal's size it may set"),
        (
            .session(mine.id), ArtifactNew(kind: .doc, title: "Plan", cwd: wt.path, session: mine.id), true,
            "it makes a page for the user"
        ),
        (
            .session(mine.id),
            ArtifactAdd(
                url: "https://claude.ai/artifact/x", title: "Deck", type: "page", cwd: wt.path, session: mine.id),
            true, "and keeps the link to one it published"
        ),
        (
            .session(mine.id), ArtifactNew(kind: .doc, title: "Plan", cwd: elsewhere.path + "/src", session: mine.id),
            false, "but not in another's workspace, whose panel would show it"
        ),
        (
            .session(mine.id),
            ArtifactAdd(
                url: "https://claude.ai/artifact/x", title: "Deck", type: "page", cwd: elsewhere.path, session: nil),
            false, "nor keeps a link there, named by its folder alone"
        ),
        (
            .session(mine.id), ArtifactNew(kind: .doc, title: "Plan", cwd: "/usr", session: mine.id), true,
            "a folder of no project is a chat's own"
        ),
        (
            .session(mine.id), ArtifactCheck(path: wt.path + "/.kelp/artifacts/x/canvas.json"), true,
            "and checks a canvas"
        )
    ]
    try expectRows(w.d, table)
}

/// A connection's caller is looked up once and outlives its session: a restart deletes the old one's record, and a
/// program of that terminal still on its connection can't be told from an agent's any more: held to an agent's rules.
@Test func aCallerWhoseSessionIsGoneIsHeldToAnAgentsRules() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "feat/x")
    let term = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "cat"))
    // This test's connection, found as that terminal's (as a program in it is, as it connects).
    for id in 0..<64 { w.d.clients.connection(id)?.owner.withLock { $0 = .session(term.id) } }
    let phone = SettingsSet(key: "phone.url", value: .string("https://x.example"))
    _ = try await w.c.call(phone)   // a terminal of the user's is the user
    _ = try await w.c.call(SessionRestart(id: term.id))
    #expect(try w.d.sessions.store.session(term.id) == nil)   // the old record went; the connection is still its
    var refused = false
    do { _ = try await w.c.call(phone) } catch let error as RPCError where error.isRefusal { refused = true }
    #expect(refused, "a user-only call from a connection whose session's record is gone")
    #expect(w.d.callers.heldAsAgent(term.id))
    // What reads who asks from the caller's origin (`db.list`'s hidden databases, `vm.create`'s question): the same.
    #expect(w.d.sessions.store.agent(origin: term.id) != nil)
}

/// Each row's call allowed or refused by the rules (`RPCError.refused`), not by any error: a missing record or a store's
/// would pass for a refusal.
func expectRows(_ daemon: Daemon, _ table: [(Caller, any Answered, Bool, String)]) throws {
    for (caller, m, allowed, why) in table {
        var refused = false
        do { try daemon.allow(m, conn: 0, caller: caller) } catch let e as RPCError where e.isRefusal {
            refused = true
        } catch {
            Issue.record("\(why): not a refusal but \(error)")
        }
        #expect(refused != allowed, "\(why): \(caller), \(type(of: m).name)")
    }
}

/// Each method agents may call has a row in a rules table (AgentRules*Tests.swift), so taking it off the list fails
/// one: none is without.
@Test func eachMethodAgentsMayCallHasARow() throws {
    let folder = (#filePath as NSString).deletingLastPathComponent
    let text = try FileManager.default.contentsOfDirectory(atPath: folder)
        .filter { $0.hasPrefix("AgentRules") && $0.hasSuffix("Tests.swift") }
        .map { try String(contentsOfFile: folder + "/" + $0, encoding: .utf8) }.joined()
    let untested = AgentRules.methods.compactMap { Daemon.methods[$0] }.map { String(describing: $0) }
        .filter { !text.contains($0 + "(") }.sorted()
    #expect(untested.isEmpty, "\(untested.count) without a row: \(untested.joined(separator: ", "))")
}
