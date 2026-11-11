import Core
import Foundation
import Testing

@testable import Daemon

/// A database's name is its key, and its password's: Add under a name taken (in the project or in All My Databases) is
/// refused, not saved over the one that has it, which keeps its server and its password.
@Test func addingUnderATakenNameLeavesTheOneThatHasIt() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let prod = DatabaseInfo(name: "prod", engine: .postgres, host: "db.example.com", port: 5432, user: "ro")
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: prod, password: "s3cret", adding: true))
    let other = DatabaseInfo(name: " prod", engine: .postgres, host: "other.example.com", port: 5432)
    await #expect(throws: RPCError.self) {
        try await w.c.call(DatabaseSave(worktreeId: wt.id, database: other, password: "x", adding: true))
    }
    let connection = try w.d.workspaces.databases.connection(wt.id, "prod", agent: false)
    #expect(connection.password == "s3cret" && connection.database.host == "db.example.com")
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: other, library: true, adding: true))
    await #expect(throws: RPCError.self) {
        try await w.c.call(DatabaseSave(worktreeId: wt.id, database: prod, library: true, adding: true))
    }
    #expect(try w.d.workspaces.databases.library().map(\.host) == ["other.example.com"])
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: prod, password: "new"))   // an edit saves over
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "prod"))
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "prod", library: true))
}
