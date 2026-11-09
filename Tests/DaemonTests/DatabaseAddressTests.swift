import Core
import Foundation
import Testing

@testable import Daemon

// Where a project's files may aim Kelp's connections and the user's secrets.

/// What the user let agents do with a found database stays with its address: a pulled .env that aims the same name at
/// another host is production again, read-only for agents.
@Test func aFoundDatabasesSettingsDontFollowItsNameToAnotherHost() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let env = wt.path + "/.env"
    try "DATABASE_URL=postgres://app@localhost:5432/app\n".write(toFile: env, atomically: true, encoding: .utf8)
    var app = try #require(try await w.c.call(DatabaseList(worktreeId: wt.id)).first)
    #expect(!app.production)
    app.access = .free
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: app))
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).first?.access == .free)
    try "DATABASE_URL=postgres://app@db.example.com:5432/app\n".write(toFile: env, atomically: true, encoding: .utf8)
    let moved = try #require(try await w.c.call(DatabaseList(worktreeId: wt.id)).first)
    #expect(moved.name == "app" && moved.production && moved.agentAccess == .read)
}

/// This Mac is a loopback address or its own name; a `.local` name, one without a dot and an IPv6 address elsewhere
/// are someone else's: no ~/.pgpass for them, and they count as production.
@Test func onlyLoopbackAndThisMacsNameAreThisMac() {
    for host in ["localhost", "127.0.0.1", "127.0.1.1", "::1", "[::1]", "host.docker.internal", "app.localhost"] {
        #expect(DatabaseFind.isLocal(host), "\(host)")
    }
    for host in ["pg.local", "db", "2001:db8::bad", "fe80::1%en0", "db.example.com"] {
        #expect(!DatabaseFind.isLocal(host), "\(host)")
        #expect(!PgPass.mayUse(for: DatabaseInfo(name: "app", engine: .postgres, source: ".env"), host: host))
    }
    let found = DatabaseInfo(name: "app", engine: .postgres, source: ".env", host: "pg.local", database: "app")
    #expect(DatabaseFind.isProduction(found))
}
