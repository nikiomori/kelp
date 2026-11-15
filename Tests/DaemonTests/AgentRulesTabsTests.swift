import Core
import Foundation
import Testing

@testable import Daemon

// The agent rules' table (`whoMayDoWhat`), for the tabs an agent opens (`kelp open`): the window opens them as the user.

/// A tab whose address names a workspace (`db:<workspace>/…`, `diff:<workspace>`) is held to the agent's workspaces as a
/// field naming it would be; a database's tab reads it as the user, so an agent opens one only of a database it may
/// use (`kelp db list`); a plain page tab has the user's cookies, so an agent's opens with its own
/// (`kelp browser open`).
@Test func anAgentsTabsShowOnlyItsOwnWorkspacesAndNoLoggedInPage() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w), elsewhere = try await workspace(w, "feat/o")
    var mine = Session(worktreeId: wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    mine.agent = "claude"
    try w.d.sessions.store.save(mine)
    let own = Caller.session(mine.id)
    // The project's databases: one agents may use, one hidden from them, and one a file of the project aims at a host
    // the user hasn't opened yet.
    let dbs = w.d.workspaces.databases
    _ = try dbs.save(wt.id, DatabaseInfo(name: "db", engine: .sqlite, path: "/tmp/x.db"), password: nil)
    _ = try dbs.save(
        wt.id, DatabaseInfo(name: "prod", engine: .postgres, host: "db.example.com", access: .hidden), password: nil)
    try "DATABASE_URL=postgres://app@pg.example.com:5432/app\n".write(
        toFile: wt.path + "/.env", atomically: true, encoding: .utf8)
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).map(\.name).sorted() == ["app", "db", "prod"])
    try expectRows(
        w.d,
        [
            (
                own, UIOpen(uri: DatabaseTabURI.uri(worktree: elsewhere.id, name: "prod")), false,
                "not another workspace's database: the window reads it as the user"
            ),
            (
                own, UIOpen(uri: "db:?" + elsewhere.id + "/db", worktreeId: wt.id), false,
                "nor one behind a `?`, which the tab reads past to the id"
            ),
            (
                own, UIOpen(uri: DatabaseTabURI.uri(worktree: wt.id, name: "prod")), false,
                "nor one of its own workspace that's hidden from agents"
            ),
            (own, UIOpen(uri: "DB:" + wt.id + "/prod"), false, "however its scheme is spelled"),
            (own, UIOpen(uri: DatabaseTabURI.uri(worktree: wt.id, name: "none")), false, "nor one that isn't there"),
            (
                own, UIOpen(uri: DatabaseTabURI.uri(worktree: wt.id, name: "app")), false,
                "nor an address from the project's files, which the tab would have kelpd dial"
            ),
            (.user, UIOpen(uri: DatabaseTabURI.uri(worktree: wt.id, name: "prod")), true, "the user opens any"),
            (
                own, UIOpen(uri: "diff:" + elsewhere.id, worktreeId: wt.id), false,
                "nor another's changes, whatever workspace the tab opens in"
            ),
            (
                own,
                UIOpen(
                    uri: "commit:%" + String(format: "%02X", elsewhere.id.utf8.first ?? 0)
                        + elsewhere.id.dropFirst() + "?push=1", worktreeId: wt.id), false,
                "nor one whose address spells the id percent-encoded, as the tab decodes it"
            ),
            (own, UIOpen(uri: DatabaseTabURI.uri(worktree: wt.id, name: "db")), true, "its own workspace's it opens"),
            (own, UIOpen(uri: "file:///tmp/a.txt"), true, "and a file"),
            (own, UIOpen(uri: "https://mail.example/inbox"), false, "not a page logged in as the user"),
            (own, UIOpen(uri: "HTTP://mail.example/inbox"), false, "however its scheme is spelled"),
            (own, UIOpen(uri: "preview:/tmp/a.html"), false, "nor a local page, which can go on to any site"),
            (.user, UIOpen(uri: "https://mail.example/inbox"), true, "the user opens any page"),
            (.user, UIOpen(uri: DatabaseTabURI.uri(worktree: elsewhere.id, name: "prod")), true, "and any database")
        ])
}
