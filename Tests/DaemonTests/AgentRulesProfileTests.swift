import Core
import Foundation
import Testing

@testable import Daemon

// The agent rules' table (`whoMayDoWhat`), for the user's accounts: what an agent starts runs under its own.

/// An agent starts a child, restarts or hands off under its own account (`profile`), never another of the user's
/// (`accounts.*`): those are the user's to pick, in Kelp's window or a terminal of theirs.
@Test func anAgentStartsSessionsUnderItsOwnAccount() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "feat/x")
    var mine = Session(worktreeId: wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    mine.agent = "claude"
    mine.profile = "work"
    var kid = Session(worktreeId: wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    kid.agent = "claude"
    kid.parent = mine.id
    try w.d.sessions.store.save(mine)
    try w.d.sessions.store.save(kid)
    let own = Caller.session(mine.id)
    try expectRows(
        w.d,
        [
            (own, SessionCreate(worktreeId: wt.id, agent: "claude", parent: mine.id), true, "a child, as it is"),
            (
                own, SessionCreate(worktreeId: wt.id, agent: "claude", profile: "work", parent: mine.id), true,
                "under its own account"
            ),
            (
                own, SessionCreate(worktreeId: wt.id, agent: "claude", profile: "personal", parent: mine.id), false,
                "not under another of the user's"
            ),
            (own, SessionRestart(id: kid.id, profile: "personal"), false, "nor moves its child to one"),
            (.detached, SessionCreate(cwd: "/tmp", command: "cat"), true, "from nowhere, a terminal"),
            (
                .detached, SessionCreate(cwd: "/tmp", command: "cat", profile: "work"), false,
                "under no account of its own"
            ),
            (.user, SessionCreate(worktreeId: wt.id, agent: "claude", profile: "personal"), true, "the user picks any")
        ])
}
