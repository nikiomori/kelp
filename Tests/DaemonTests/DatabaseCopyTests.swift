import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Daemon

// A branch's own copy of a project's database: whose it is, what agents may do there, and how it goes.

private func shop(in root: String) throws -> String {
    let dir = (root as NSString).appendingPathComponent("db")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent("shop.sqlite3")
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT)")
        try db.execute(sql: "INSERT INTO orders VALUES (1, 'pending'), (2, 'pending')")
    }
    try queue.close()
    return path
}

private func list(_ w: World, _ worktree: Worktree) async throws -> [DatabaseInfo] {
    try await w.c.call(DatabaseList(worktreeId: worktree.id))
}

/// The copy says whose it is and what it's of; agents change it without asking, whatever the project's database
/// lets them, and what the user says of either leaves the other as it was. Dropped, its file is gone and the
/// project's database is the workspace's again.
@Test func aBranchesCopyIsItsOwnAndIsDroppedByHand() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let main = try await firstWorkspace(w)
    let original = try shop(in: main.path)
    var project = try #require(try await list(w, main).first)
    project.access = .read
    _ = try await w.c.call(DatabaseSave(worktreeId: main.id, database: project))
    let branch = try await workspace(w, "fix/orders")

    let copy = try await w.c.call(DatabaseCopy(worktreeId: branch.id, database: "shop"))
    #expect(copy.copy?.of == "shop" && copy.copy?.worktreeId == branch.id && copy.access == .free)
    #expect(try await list(w, branch).map(\.copy?.of) == ["shop"])
    let projects = try await list(w, main)
    #expect(projects.map(\.copy) == [nil] && projects.first?.access == .read)

    var mine = copy
    mine.access = .ask
    _ = try await w.c.call(DatabaseSave(worktreeId: branch.id, database: mine))
    let said = try #require(try await list(w, branch).first)
    #expect(said.access == .ask && said.copy?.of == "shop" && said.path == copy.path)
    #expect(try await list(w, main).first?.access == .read)   // the project's own settings weren't written over

    _ = try await w.c.call(DatabaseCopyRemove(worktreeId: branch.id, database: "shop"))
    #expect(!FileManager.default.fileExists(atPath: copy.path ?? ""))
    let back = try #require(try await list(w, branch).first)
    #expect(back.path == original && back.copy == nil && back.access == .read)
    await expectRefusal(says: "isn't this workspace's copy") {   // the project's own isn't a copy to drop
        try await w.c.call(DatabaseCopyRemove(worktreeId: branch.id, database: "shop"))
    }
    #expect(FileManager.default.fileExists(atPath: original))
}

/// A copy made beside the project's file is its workspace's: another workspace of the project doesn't list it, and
/// with its workspace gone Kelp keeps nothing of it.
@Test func aCopyIsListedInItsWorkspaceOnlyAndGoesWithIt() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let main = try await firstWorkspace(w)
    _ = try shop(in: main.path)
    let branch = try await workspace(w, "fix/orders")
    let beside = try await w.c.call(DatabaseCopy(worktreeId: main.id, database: "shop"))
    #expect(beside.name == "shop_main" && beside.copy?.worktreeId == main.id)
    #expect(try await list(w, main).map(\.name).sorted() == ["shop", "shop_main"])
    #expect(try await list(w, branch).map(\.name) == ["shop"])

    _ = try await w.c.call(DatabaseCopy(worktreeId: branch.id, database: "shop"))
    func kept() throws -> [String] {
        try w.d.store.db.read { try SavedDatabase.fetchAll($0) }.map(\.id).filter { $0.hasSuffix("@" + branch.id) }
    }
    #expect(try kept().count == 1)
    _ = try await w.c.call(WorktreeRemove(id: branch.id, force: true))
    #expect(try await waitFor { try kept().isEmpty })
}

/// A branch's copy is the agents' to change, unless the original keeps its rows from them: hidden stays hidden, and
/// structure only stays structure only, since the copy holds the same rows.
@Test func aCopyKeepsAgentsFromRowsTheOriginalKeepsThemFrom() {
    let rows: [(DatabaseInfo.Access, DatabaseInfo.Access)] = [
        (.hidden, .hidden), (.structure, .structure), (.read, .free), (.ask, .free), (.free, .free)
    ]
    for (original, copy) in rows {
        let made = Databases.asCopy(DatabaseInfo(name: "shop", engine: .sqlite, access: original), of: "shop", for: "w")
        #expect(made.access == copy, "\(original)")
    }
}
