import Core
import Foundation
import Testing

@testable import Daemon

// The agent rules' table (`whoMayDoWhat`), for the tabs an agent opens (`kelp open`): the window opens them as the user.

/// A tab whose address names a workspace (`db:<workspace>/…`, `diff:<workspace>`) is held to the agent's workspaces as a
/// field naming it would be; a plain page tab has the user's cookies, so an agent's opens with its own
/// (`kelp browser open`).
@Test func anAgentsTabsShowOnlyItsOwnWorkspacesAndNoLoggedInPage() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w), elsewhere = try await workspace(w, "feat/o")
    var mine = Session(worktreeId: wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    mine.agent = "claude"
    try w.d.sessions.store.save(mine)
    let own = Caller.session(mine.id)
    try expectRows(
        w.d,
        [
            (
                own, UIOpen(uri: DatabaseTabURI.uri(worktree: elsewhere.id, name: "prod")), false,
                "not another workspace's database: the window reads it as the user"
            ),
            (
                own, UIOpen(uri: "diff:" + elsewhere.id, worktreeId: wt.id), false,
                "nor another's changes, whatever workspace the tab opens in"
            ),
            (own, UIOpen(uri: DatabaseTabURI.uri(worktree: wt.id, name: "db")), true, "its own workspace's it opens"),
            (own, UIOpen(uri: "file:///tmp/a.txt"), true, "and a file"),
            (own, UIOpen(uri: "https://mail.example/inbox"), false, "not a page logged in as the user"),
            (own, UIOpen(uri: "HTTP://mail.example/inbox"), false, "however its scheme is spelled"),
            (.user, UIOpen(uri: "https://mail.example/inbox"), true, "the user opens any page"),
            (.user, UIOpen(uri: DatabaseTabURI.uri(worktree: elsewhere.id, name: "prod")), true, "and any database")
        ])
}
