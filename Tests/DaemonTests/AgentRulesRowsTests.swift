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
    // A workspace of the agent's alone (its own session is all that runs there), and a session it started.
    let solo = Worktree(repoId: w.repo.id, branch: "solo", path: "/tmp/solo")
    var alone = Session(worktreeId: solo.id, cwd: "/tmp", command: "claude", argv: ["claude"])
    alone.agent = "claude"
    var child = Session(worktreeId: wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    child.parent = mine.id
    for record in [mine, theirs, alone, child] { try w.d.sessions.store.save(record) }
    try w.d.sessions.store.save(elsewhere)
    try w.d.sessions.store.save(solo)
    let typed = Caller.typedAgent(term.id)
    let phone = SettingsSet(key: "phone.url", value: .string("https://x.example")),
        font = SettingsSet(key: "editor.fontSize", value: .int(13))
    let table: [(Caller, any Answered, Bool, String)] = [
        (.kelpd, font, true, "kelpd's program is held to an agent's rules: a look it may set"),
        (.kelpd, phone, false, "the user's settings it may not"),
        (.kelpd, SessionKill(id: term.id), false, "nor end the user's terminal"),
        (.unknown, font, true, "one gone as it connected is held to an agent's rules too"),
        (.unknown, phone, false, "the user's settings it may not"),
        (.unknown, SessionKill(id: term.id), false, "nor end the user's terminal"),
        (.session(term.id), SessionReport(id: term.id, state: "done"), true, "a session reports for itself"),
        (.session(alone.id), WorktreeRemove(id: solo.id), true, "it removes a workspace of its own"),
        (.session(alone.id), WorktreeArchive(id: solo.id), true, "or archives it"),
        (.session(alone.id), WorktreeRemove(id: solo.id, force: true), false, "but not with changes in it"),
        (.session(alone.id), WorktreeRemove(id: solo.id, dropCommits: true), false, "nor with commits only there"),
        (.session(mine.id), WorktreeRemove(id: elsewhere.id), false, "it doesn't remove another's workspace"),
        (.session(mine.id), WorktreeArchive(id: elsewhere.id), false, "nor archive it"),
        (
            .session(mine.id), SessionCreate(worktreeId: wt.id, command: "cat", tmux: "work"), false,
            "nor starts a tmux session, which would attach to the user's of that name"
        ),
        (.session(mine.id), SessionRename(id: mine.id, title: "x"), true, "it names its own session"),
        (.session(mine.id), SessionMarkRead(id: mine.id), true, "and marks it read"),
        (.session(mine.id), SessionPermissionWait(id: mine.id), true, "and waits on its own question"),
        (.session(mine.id), SessionSend(id: child.id, text: "go"), true, "it sends into a session it started"),
        (.session(mine.id), CommentSend(id: wt.id, session: child.id), true, "and its comments there"),
        (.session(mine.id), UIBrowserAsk(question: "Sign in", worktreeId: wt.id), true, "it hands its page over"),
        (.session(mine.id), GitRemoteOp(id: elsewhere.id, op: .fetch), false, "nor fetch there"),
        (.session(mine.id), GitRemoteOp(id: wt.id, op: .fetch), true, "in its own it fetches"),
        (.session(mine.id), GitRemoteOp(id: wt.id, op: .push), false, "but never pushes"),
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
            .session(mine.id), SessionCreate(cwd: elsewhere.path, worktreeId: wt.id, command: "cat"), false,
            "it starts no session in another's workspace, by its folder"
        ),
        (
            .session(mine.id), SessionCreate(cwd: wt.path + "/src", worktreeId: wt.id, command: "cat"), true,
            "but in its own, at any folder"
        ),
        (
            .session(mine.id), SessionCreate(cwd: "/usr", worktreeId: wt.id, command: "cat"), true,
            "or in a folder of no project"
        ),
        (.session(mine.id), VMConnect(name: "linux", cwd: elsewhere.path), false, "nor runs a machine's command there"),
        (.session(mine.id), VMConnect(name: "linux", cwd: wt.path), true, "but does in its own"),
        (
            .session(mine.id), ArtifactCheck(path: wt.path + "/.kelp/artifacts/x/canvas.json"), true,
            "and checks a canvas"
        ),
        (
            .session(mine.id), ArtifactReply(path: wt.path + "/.kelp/artifacts/x/canvas.json", id: 1, text: "?"), true,
            "it answers a mark on a page in its workspace"
        ),
        (
            .session(mine.id), ArtifactReply(path: elsewhere.path + "/.kelp/artifacts/x/canvas.json", id: 1, text: "?"),
            false, "but not on one in another's"
        ),
        (
            .session(mine.id), ArtifactAsk(path: wt.path + "/.kelp/artifacts/x/motion.html", id: "t", text: "?"), true,
            "it asks about an element of a page in its workspace"
        ),
        (
            .session(mine.id), ArtifactSuggest(path: elsewhere.path + "/.kelp/artifacts/x/motion.html", lines: ["a"]),
            false, "and offers what's next, but not on another's"
        ),
        (
            .session(mine.id), ArtifactSuggest(path: wt.path + "/.kelp/artifacts/x/motion.html", lines: ["a"]), true,
            "only on its own"
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

/// Expects `call` refused: by the rules (`RPCError.refused`), or, given `says`, by an error whose message says that
/// (any case), the reason. Any error isn't enough: a missing record, a timeout or a failed git would pass for one.
func expectRefusal<T>(
    says: String? = nil, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation,
    _ call: () async throws -> T
) async {
    let e = await #expect(throws: RPCError.self, comment, sourceLocation: sourceLocation) { _ = try await call() }
    guard let e else { return }
    let refused = says.map { e.message.localizedCaseInsensitiveContains($0) } ?? e.isRefusal
    #expect(
        refused, "\(comment.map { "\($0): " } ?? "")\(says ?? "a rules refusal") ≠ \(e.message)",
        sourceLocation: sourceLocation)
}

/// Each method agents may call has a row in a rules table (AgentRules*Tests.swift) that allows it, so taking it off the
/// list fails one: a row that refuses it passes either way. Allowed is `(caller, Name(…), true, …)`, or a `calls` list,
/// which each of those tests allows its agent.
@Test func eachMethodAgentsMayCallHasARow() throws {
    let folder = (#filePath as NSString).deletingLastPathComponent
    let text = try FileManager.default.contentsOfDirectory(atPath: folder)
        .filter { $0.hasPrefix("AgentRules") && $0.hasSuffix("Tests.swift") }
        .map { try String(contentsOfFile: folder + "/" + $0, encoding: .utf8) }.joined()
    // Calls in code only: a name in a comment, or one ending another's (`Status(` in `GitStatus(`), isn't a row. A
    // comment starts at `//` after a space (a URL's `://` isn't one).
    let code = text.replacing(/(^|\s)\/\/.*/.anchorsMatchLineEndings(), with: "")
    let lists = code.matches(of: /let calls[^=]*=\s*\[([\s\S]*?)\n    \]/).map { String($0.1) }.joined()
    func allowed(_ name: String) -> Bool {
        // Its arguments, two calls deep (`UIOpen(uri: DatabaseTabURI.uri(…))`), then `, true`.
        let row = #"\b"# + name + #"\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)\s*,\s*true\b"#
        return code.range(of: row, options: .regularExpression) != nil
            || lists.range(of: #"\b"# + name + #"\("#, options: .regularExpression) != nil
    }
    let untested = AgentRules.methods.compactMap { Daemon.methods[$0] }.map { String(describing: $0) }
        .filter { !allowed($0) }.sorted()
    #expect(untested.isEmpty, "\(untested.count) without a row that allows it: \(untested.joined(separator: ", "))")
}
