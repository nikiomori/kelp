import Agents
import Core
import Foundation
import GRDB
import NIOSSL
import PostgresNIO
import TestSupport
import Testing

@testable import Daemon

// Where a project's files may aim Kelp's connections and the user's secrets.

/// What the user let agents do with a found database stays with its address: a pulled .env that aims the same name at
/// another host is read-only for agents again (not production: only the user says that).
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
    #expect(moved.name == "app" && !moved.production && moved.agentAccess == .read)
}

/// This Mac is a loopback address or its own name; a `.local` name, one without a dot and an IPv6 address elsewhere
/// are someone else's: no ~/.pgpass for them, and agents only read them until the user says otherwise.
@Test func onlyLoopbackAndThisMacsNameAreThisMac() {
    let here = [
        "localhost", "127.0.0.1", "127.0.1.1", "127.255.0.9", "::1", "[::1]", "host.docker.internal", "a.localhost"
    ]
    for host in here {
        #expect(DatabaseInfo.isLocal(host), "\(host)")
    }
    for host in [
        "pg.local", "db", "2001:db8::bad", "fe80::1%en0", "db.example.com", "127.evil.example", "127.0.0.1.nip.io",
        "127.0.0.256", "127.1", "127.+0.0.1"
    ] {
        #expect(!DatabaseInfo.isLocal(host), "\(host)")
        #expect(!PgPass.mayUse(for: DatabaseInfo(name: "app", engine: .postgres, source: ".env"), host: host))
    }
    let found = DatabaseInfo(name: "app", engine: .postgres, source: ".env", host: "pg.local", database: "app")
    #expect(DatabaseFind.isRemote(found))
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

/// Production marks kept before they were the user's word only go once; a server elsewhere stays read only for agents.
@Test func guessedProductionMarksGoOnceAndElsewhereStaysReadOnly() throws {
    let queue = try DatabaseQueue()
    try Store.migrator.migrate(queue, upTo: "databaseLibrary")
    var remote = DatabaseInfo(name: "bi", engine: .postgres, host: "db.example.com", access: .ask)
    remote.set(stage: .production)
    var local = DatabaseInfo(name: "app", engine: .postgres, host: "localhost", access: .free, production: true)
    local.environment = .production
    let staged = DatabaseInfo(name: "dev", engine: .postgres, host: "dev.example.com", access: .ask)
    try queue.write { db in
        for info in [remote, local, staged] {
            try db.execute(
                sql: "INSERT INTO databaseLibrary (id, json) VALUES (?, ?)",
                arguments: [info.name, String(decoding: try JSONEncoder().encode(info), as: UTF8.self)])
        }
    }
    try Store.migrator.migrate(queue)
    let after = try queue.read { db in
        try String.fetchAll(db, sql: "SELECT json FROM databaseLibrary ORDER BY id").map {
            try JSONDecoder().decode(DatabaseInfo.self, from: Data($0.utf8))
        }
    }
    #expect(after.map(\.name) == ["app", "bi", "dev"])
    #expect(after.allSatisfy { !$0.production && $0.environment == nil })
    #expect(after[0].access == .free && after[1].access == .read)
    #expect(after[2].access == .ask)   // not marked before: left as it was
}

/// An .env's URL is read as the same line pasted into Add Database is: its schemes, its sslmode.
@Test func anEnvURLReadsAsAPastedOne() {
    let text = "DATABASE_URL=pg://app@db.example.com/app_dev?sslmode=require\nPG_URL=postgres:///local"
    let found = DatabaseFind.env(text, source: ".env", root: "/p")
    #expect(found.count == 2)
    #expect(found.first?.database.engine == .postgres && found.first?.database.ssl == "require")
    #expect(found.first?.database.source == ".env" && found.first?.database.name == "app_dev")
    #expect(found.last?.database.host == "localhost" && found.last?.database.database == "local")
}

/// An address's sslmode is kept as it asks: verify-ca checks the server's certificate against root.crt alone (none
/// there: refused, not checked against the Mac's roots), verify-full its name too, which an IP address can't be
/// checked against (refused, not checked less); require and prefer take any certificate.
@Test func verifyModesCheckTheServersCertificate() throws {
    let modes: [(String, String?)] = [
        ("require", "require"), ("verify-ca", "verify-ca"), ("VERIFY_CA", "verify-ca"), ("verify-full", "verify-full"),
        ("VERIFY_IDENTITY", "verify-full"), ("prefer", nil), ("disable", "disable")
    ]
    for (mode, kept) in modes { #expect(DatabaseAddress.ssl(mode) == kept, "\(mode)") }
    let root = tmp().appendingPathComponent("root-\(UUID().uuidString).crt").path
    try "".write(toFile: root, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: root) }
    func tls(
        _ ssl: String?, _ host: String = "db.example.com", _ engine: DatabaseInfo.Engine = .postgres,
        root: String = root
    ) throws -> TLSConfiguration {
        var db = DatabaseInfo(name: "app", engine: engine, host: host, port: 5432)
        db.ssl = ssl
        return try DatabaseWire.tls(db, root: root)
    }
    func checks(_ ssl: String?, _ host: String = "db.example.com") throws -> CertificateVerification {
        try tls(ssl, host).certificateVerification
    }
    #expect(try checks("verify-full") == .fullVerification)
    #expect(try tls("verify-full").trustRoots == .default)   // the Mac's roots, root.crt besides
    #expect(try checks("verify-ca", "10.0.0.5") == .noHostnameVerification)
    for engine in [DatabaseInfo.Engine.postgres, .mysql] {
        #expect(try tls("verify-ca", "db.example.com", engine).trustRoots == .file(root), "\(engine)")
        #expect(throws: DatabaseFailure.self) { try tls("verify-ca", "db.example.com", engine, root: root + ".none") }
    }
    #expect(try checks("require") == .none)
    #expect(try checks(nil) == .none)
    #expect(throws: DatabaseFailure.self) { try checks("verify-full", "10.0.0.5") }
    #expect(DatabaseWire.requiresTLS(DatabaseInfo(name: "a", engine: .mysql, ssl: "verify-ca")))
}

/// A server reached through a forwarded port (behind an SSH host, a remote project's) is at localhost here, and its
/// certificate is still checked against its own name.
@Test func aForwardedServersCertificateIsCheckedAgainstItsOwnName() throws {
    var db = DatabaseInfo(name: "app", engine: .postgres, host: "db.internal.example", port: 5432)
    db.ssl = "verify-full"
    let near = Databases.forwarded(DatabaseConnection(database: db), to: 61_000)
    #expect(near.database.host == "localhost" && near.database.port == 61_000)
    #expect(try PostgresWire.configuration(near).options.tlsServerName == "db.internal.example")
    db.host = "10.0.0.5"   // an address can't be checked by name, forwarded or not
    #expect(throws: DatabaseFailure.self) {
        try PostgresWire.configuration(Databases.forwarded(.init(database: db), to: 1))
    }
}

/// Each wire connection to Postgres has a name of its own after "kelp/", by which a Stop finds its statement on the
/// server; the statement that cancels it binds that name rather than writing it into the SQL.
@Test func aStoppedPostgresStatementIsFoundByItsConnectionsName() throws {
    let name = PostgresWire.applicationName()
    #expect(name.hasPrefix("kelp/") && name != PostgresWire.applicationName())
    let db = DatabaseInfo(name: "app", engine: .postgres, host: "localhost", port: 5432)
    let options = try PostgresWire.configuration(DatabaseConnection(database: db), name: name).options
    #expect(options.additionalStartupParameters.contains { $0 == ("application_name", name) })
    let cancel = PostgresWire.cancelQuery(name)
    #expect(cancel.sql.hasSuffix("application_name = $1") && cancel.binds.count == 1 && !cancel.sql.contains(name))
}
