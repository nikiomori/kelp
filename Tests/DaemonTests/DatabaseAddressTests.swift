import Agents
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

/// A Postgres behind an SSH host is that host's: its "localhost" isn't this Mac's, so Kelp doesn't copy it here.
@Test func aPostgresBehindAnSSHHostIsntCopiedOnThisMac() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let branch = try await workspace(w, "fix/orders")
    var db = DatabaseInfo(name: "app", engine: .postgres, host: "localhost", port: 5432, database: "app")
    db.ssh = "bastion"
    _ = try await w.c.call(DatabaseSave(worktreeId: branch.id, database: db))
    do {
        _ = try await w.c.call(DatabaseCopy(worktreeId: branch.id, database: "app"))
        Issue.record("copied")
    } catch let error as RPCError {
        #expect(error.message.contains("on this Mac"), "\(error.message)")
    }
}

/// An agent's call doesn't make kelpd dial an address from the project's files (a cloned repo's .env can name any host
/// on the user's network) until the user has opened it.
@Test func anAgentDoesntDialAnAddressFromTheFilesBeforeTheUser() async throws {
    let w = try await world(agents: [AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    try "DATABASE_URL=postgres://app@db.example.invalid:5432/app\n".write(
        toFile: wt.path + "/.env", atomically: true, encoding: .utf8)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let read = DatabaseQuery(worktreeId: wt.id, database: "app", sql: "SELECT 1")
    func why() async -> String? {
        do {
            _ = try await w.d.workspaces.databases.query(read, origin: agent.id)
            return nil
        } catch { return (error as? RPCError)?.message }
    }
    #expect(await why()?.contains("once the user opens it") == true)
    await #expect(throws: RPCError.self) { try await w.c.call(read) }   // the user's: dialled, nobody there
    #expect(await why()?.contains("once the user opens it") == false)
}
