import Agents
import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Daemon

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])

// MARK: Finding

@Test func composeServicesOfDatabaseImagesAreFound() {
    let text = """
        name: shop
        services:
          db:
            image: postgres:16
            ports:
              - "127.0.0.1:5433:5432"
            environment:
              POSTGRES_USER: app
              POSTGRES_PASSWORD: secret
              POSTGRES_DB: app_dev
          cache:
            image: redis:7
          mysql:
            image: mysql:8
            environment:
              - MYSQL_DATABASE=shop
              - MYSQL_ROOT_PASSWORD=root
        volumes:
          data:
        """
    let found = DatabaseFind.compose(text, source: "compose.yaml")
    #expect(found.count == 2)
    let pg = found[0]
    #expect(pg.database.engine == .postgres && pg.database.name == "app_dev" && pg.database.port == 5433)
    #expect(pg.database.user == "app" && pg.password == "secret" && pg.database.host == "localhost")
    let my = found[1]
    #expect(my.database.engine == .mysql && my.database.name == "shop" && my.database.port == nil)
    #expect(my.database.user == "root" && my.password == "root")
}

/// Compose fills `${VAR}` in from the .env beside it, and so does Kelp: a password kept there, a port with a default.
@Test func composeVariablesComeFromTheEnvBesideIt() {
    let compose = """
        services:
          db:
            image: postgres:16
            ports:
              - "127.0.0.1:${DB_PORT:-5440}:5432"
            environment:
              POSTGRES_USER: ${POSTGRES_USER}
              POSTGRES_PASSWORD: $POSTGRES_PASSWORD
              POSTGRES_DB: ${POSTGRES_DB-app}
        """
    let found = DatabaseFind.parse(
        [("api/compose.yaml", compose), ("api/.env", "POSTGRES_USER=niko\nPOSTGRES_PASSWORD='s3 cret'\n")], root: "/p")
    #expect(found.count == 1)
    #expect(found.first?.database.user == "niko" && found.first?.password == "s3 cret")
    #expect(found.first?.database.port == 5440 && found.first?.database.name == "app")
    #expect(found.first?.database.source == "api/compose.yaml")
    #expect(
        PostgresRun.failure(
            "psql: error: connection to server at \"localhost\" (::1), port 5432 failed: Connection refused\n"
                + "connection to server at \"localhost\" (127.0.0.1), port 5432 failed: fe_sendauth: no password supplied\n"
        )
            == .failed("fe_sendauth: no password supplied"))
}

@Test func envURLsAreFoundAndOneElsewhereIsReadOnlyButNotProduction() {
    let text = """
        # the app's
        DATABASE_URL="postgres://app:p%40ss@localhost:5432/app_dev"
        export ANALYTICS_DB_URL=mysql://ro@db.example.com/analytics
        SECRET_KEY=abc
        """
    let found = DatabaseFind.unique(DatabaseFind.env(text, source: ".env", root: "/p"))
    #expect(found.count == 2)
    #expect(found[0].database.name == "app_dev" && found[0].password == "p@ss" && !found[0].database.production)
    #expect(!found[1].database.production && found[1].database.access == .read && found[1].database.port == 3306)
    let prod = DatabaseFind.unique(
        DatabaseFind.env("DATABASE_URL=postgres://u@localhost/shop", source: ".env.production", root: "/p"))
    #expect(prod.first?.database.production == false)   // a file's name isn't the user's word
    let sqlite = DatabaseFind.env("DATABASE_URL=file:./dev.db", source: ".env", root: "/p")
    #expect(sqlite.first?.database.path == "/p/dev.db" && sqlite.first?.database.name == "dev")
}

/// Prisma's datasource when its url is written out; one from env("…") is the .env's.
@Test func aPrismaDatasourceIsFound() {
    let schema = """
        generator client {
          provider = "prisma-client-js"
        }
        datasource db {
          provider = "sqlite"
          url      = "file:./dev.db"
        }
        """
    let found = DatabaseFind.prisma(schema, source: "prisma/schema.prisma", root: "/p")
    #expect(found.first?.database.path == "/p/prisma/dev.db" && found.first?.database.engine == .sqlite)
    let fromEnv = schema.replacingOccurrences(of: "\"file:./dev.db\"", with: "env(\"DATABASE_URL\")")
    #expect(DatabaseFind.prisma(fromEnv, source: "prisma/schema.prisma", root: "/p").isEmpty)
    let pg = schema.replacingOccurrences(of: "file:./dev.db", with: "postgresql://app@localhost:5433/shop")
    #expect(DatabaseFind.prisma(pg, source: "prisma/schema.prisma", root: "/p").first?.database.port == 5433)
}

@Test func railsDevelopmentAndTestBlocksAreFound() {
    let text = """
        default: &default
          adapter: postgresql
          pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
        development:
          adapter: postgresql
          database: shop_development
          username: app
        test:
          adapter: sqlite3
          database: db/test.sqlite3
        production:
          adapter: postgresql
          database: shop_production
        """
    let found = DatabaseFind.rails(text, source: "config/database.yml", root: "/p")
    #expect(found.map(\.database.name) == ["shop_development", "test"])
    #expect(found[1].database.engine == .sqlite && found[1].database.path == "/p/db/test.sqlite3")
}

@Test func theSamePlaceFoundTwiceIsKeptOnce() {
    let a = FoundDatabase(
        database: DatabaseInfo(name: "app", engine: .postgres, host: "localhost", port: 5432, database: "app"))
    var b = a
    b.database.source = ".env"
    var c = a
    c.database.database = "other"
    let kept = DatabaseFind.unique([a, b, c])
    #expect(kept.map(\.database.name) == ["app", "app-2"])
    #expect(
        DatabaseFind.published("5433:5432", inner: 5432) == 5433 && DatabaseFind.published("6379", inner: 5432) == nil)
}

// MARK: psql's output

@Test func psqlCSVKeepsNullApartFromEmpty() {
    let null = PostgresRun.null
    let rows = PostgresRun.section("id,name,note\n1,\"a, b\",\(null)\n2,,\"say \"\"hi\"\"\"\n")
    #expect(rows.columns == ["id", "name", "note"])
    #expect(rows.rows == [["1", "a, b", nil], ["2", "", "say \"hi\""]])
    #expect(rows.total == 2)
    #expect(PostgresRun.section("UPDATE 1204\n").changed == 1204)
    let returning = PostgresRun.section("id,status\n7,cancelled\nUPDATE 1\n")   // RETURNING: the rows, then the tag
    #expect(returning.rows == [["7", "cancelled"]] && returning.changed == 1)
    #expect(PostgresRun.section("count\n").columns == ["count"])
    #expect(PostgresRun.failure("ERROR:  cannot execute UPDATE in a read-only transaction\n") == .change)
    #expect(
        PostgresRun.failure("ERROR:  relation \"x\" does not exist\nLINE 1: …")
            == .failed("relation \"x\" does not exist"))
}

// MARK: SQLite through the daemon

/// A SQLite file in the project: an `orders` table with three rows, two of them pending.
private func shopDB(in root: String) throws -> String {
    let dir = (root as NSString).appendingPathComponent("db")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent("shop.sqlite3")
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute(
            sql: """
                CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), status TEXT NOT NULL,
                note TEXT)
                """)
        try db.execute(sql: "INSERT INTO users VALUES (1, 'ann')")
        try db.execute(
            sql: "INSERT INTO orders VALUES (1, 1, 'paid', NULL), (2, 1, 'pending', ''), (3, 1, 'pending', 'x')")
    }
    try queue.close()
    return path
}

private func count(_ path: String, _ sql: String) throws -> Int {
    try DatabaseQueue(path: path).read { try Int.fetchOne($0, sql: sql) ?? -1 }
}

/// The user finds the project's SQLite file, reads its schema, and runs a read and a change of their own: nobody asks.
@Test func theUserReadsAndChangesAFoundSQLiteDatabase() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try shopDB(in: wt.path)
    let list = try await w.c.call(DatabaseList(worktreeId: wt.id))
    #expect(list.map(\.name) == ["shop"] && list[0].source == "db/shop.sqlite3" && list[0].access == .ask)

    let schema = try await w.c.call(DatabaseSchemaRead(worktreeId: wt.id, database: "shop", table: "orders"))
    let orders = try #require(schema.tables.first)
    #expect(orders.rows == 3 && orders.columns.map(\.name) == ["id", "user_id", "status", "note"])
    #expect(orders.columns[0].primary && orders.columns[1].references == "users.id" && !orders.columns[2].nullable)

    let read = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT * FROM orders", limit: 2))
    #expect(read.columns == ["id", "user_id", "status", "note"] && read.rows.count == 2 && read.total == 3)
    #expect(read.rows[0][3] == nil && read.rows[1][3] == "")
    // The user's own read keeps no rows: they came back with it (an agent's are kept, for its run's tab)
    #expect(try await w.c.call(DatabaseResultRead(worktreeId: wt.id, id: read.id)) == nil)

    let change = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET status = 'paid' WHERE id = 2"))
    #expect(change.changed == 1)
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'paid'") == 2)
    await #expect(throws: RPCError.self) {
        try await w.c.call(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT 1; DELETE FROM orders"))
    }
    let activity = try await w.c.call(DatabaseActivity(worktreeId: wt.id))
    #expect(activity.runs.map(\.state) == [.done, .done] && activity.runs.allSatisfy { $0.session == nil })
}

/// An agent reads freely; its change is tried and rolled back, asked on its row as a permission is ("Allow changing 2
/// rows of orders in shop?"), and runs once the user allows it. Denied, nothing changes and the agent is told so.
@Test func anAgentsChangeWaitsForTheUsersAllow() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try shopDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let dbs = w.d.workspaces.databases
    let update = DatabaseQuery(
        worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET status = 'cancelled' WHERE status = 'pending'")

    let read = try await dbs.query(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT count(*) AS n FROM orders"), origin: agent.id)
    #expect(read.rows == [["3"]])

    func ask() -> Task<QueryResult, Error> { Task { try await dbs.query(update, origin: agent.id) } }
    /// The question its row asks once a new run waits (not the last one's, which the row may still say).
    func asked(after last: String? = nil) async throws -> (String, String) {
        var run: DatabaseRun?
        _ = try await waitFor {
            run = try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first {
                $0.state == .asks && $0.id != last
            }
            // its run is noted a moment before its row asks
            return try run != nil && w.d.store.session(agent.id)?.summary.hasPrefix("Allow") == true
        }
        return (try w.d.store.session(agent.id)?.summary ?? "", run?.id ?? "")
    }

    let first = ask()
    let (question, firstRun) = try await asked()
    #expect(question == "Allow changing 2 rows of orders in shop?")
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'cancelled'") == 0)   // rolled back
    let asking = try #require(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first)
    #expect(asking.state == .asks && asking.session == agent.id && asking.changed == 2)
    let preview = try await w.c.call(DatabaseResultRead(worktreeId: wt.id, id: asking.id))
    #expect(preview?.rows.map { $0[2] } == ["cancelled", "cancelled"])   // RETURNING: the rows as they'd be
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "deny", question: question)))
    await #expect(throws: RPCError.self) { try await first.value }
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'cancelled'") == 0)

    let second = ask()
    let (again, _) = try await asked(after: firstRun)
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: again)))
    #expect(try await second.value.changed == 2)
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'cancelled'") == 2)
    let runs = try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs
    #expect(runs.prefix(2).map(\.state) == [.done, .denied])
}

/// Read-only for agents, hidden from them, production: what the user set holds, and the user's own change still runs.
@Test func whatAgentsMayDoIsTheDatabasesSay() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    _ = try shopDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let dbs = w.d.workspaces.databases
    var shop = try #require(try await w.c.call(DatabaseList(worktreeId: wt.id)).first)
    shop.access = .read
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: shop))
    let change = DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "DELETE FROM orders")
    await #expect(throws: RPCError.self) { try await dbs.query(change, origin: agent.id) }
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first?.state == .refused)

    shop.access = .free
    shop.production = true   // production: read only for agents, whatever access says
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: shop))
    await #expect(throws: RPCError.self) { try await dbs.query(change, origin: agent.id) }
    shop.production = false
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: shop))
    #expect(try await dbs.query(change, origin: agent.id).changed == 3)   // free: no question

    shop.access = .hidden
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: shop))
    await #expect(throws: RPCError.self) {
        try await dbs.query(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT 1"), origin: agent.id)
    }
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).count == 1)   // the user still sees it
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "shop"))
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).first?.access == .ask)   // back as it was found
    // Settings › Databases: what agents may do with a found one, and how many rows they get.
    _ = try await w.c.call(SettingsSet(key: SettingKeys.databaseAccess.key, value: .string("free")))
    _ = try await w.c.call(SettingsSet(key: SettingKeys.databaseRows.key, value: .int(1)))
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).first?.access == .free)
    let few = try await dbs.query(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT 1 UNION SELECT 2"), origin: agent.id)
    #expect(few.rows.count == 1 && few.total == 2)
    // Past what Settings offers (settings.json, an agent's `kelp settings set`): held to it, not a trap in kelpd.
    _ = try await w.c.call(SettingsSet(key: SettingKeys.databaseRows.key, value: .double(1e300)))
    _ = try await w.c.call(SettingsSet(key: SettingKeys.databaseTimeout.key, value: .double(1e300)))
    let all = try await dbs.query(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT 1 UNION SELECT 2"), origin: agent.id)
    #expect(all.rows.count == 2)
}

/// One added by hand keeps its password in the keychain, never in what's sent.
@Test func aDatabaseAddedByHandKeepsItsPasswordInTheKeychain() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let db = DatabaseInfo(
        name: "prod", engine: .postgres, host: "db.example.com", port: 5432, database: "shop", user: "ro")
    let saved = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: db, password: "s3cret"))
    #expect(saved.name == "prod")
    let list = try await w.c.call(DatabaseList(worktreeId: wt.id))
    #expect(list.map(\.name) == ["prod"])
    _ = try shopDB(in: wt.path)   // found: "shop", which one added by hand can't be called
    await #expect(throws: RPCError.self) {
        try await w.c.call(
            DatabaseSave(worktreeId: wt.id, database: DatabaseInfo(name: "shop", engine: .sqlite, path: "/tmp/x.db")))
    }
    let connection = try w.d.workspaces.databases.connection(wt.id, "prod", agent: false)
    #expect(connection.password == "s3cret")
    let sent = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
    #expect(!sent.contains("s3cret"))
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "prod"))
    #expect(Keychain.get(Databases.account(w.repo.id + "/prod")) == nil)
}

/// A project's files can't aim the user's own secrets or Kelp's connections at a host they name: ~/.pgpass only for a
/// server the user added or one on this Mac, and a found server elsewhere is dialled only when opened.
@Test func aHostFromTheProjectsFilesGetsNoPgPassAndIsntDialledUnasked() async throws {
    let found = DatabaseInfo(name: "app", engine: .postgres, source: ".env", host: "db.evil.example")
    #expect(!PgPass.mayUse(for: found, host: "db.evil.example"))
    #expect(PgPass.mayUse(for: DatabaseInfo(name: "x", engine: .postgres, source: ".env"), host: "localhost"))
    #expect(PgPass.mayUse(for: DatabaseInfo(name: "x", engine: .postgres), host: "db.example.com"))   // the user's
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    try "DATABASE_URL=postgres://app@db.evil.example:5432/app\n".write(
        toFile: wt.path + "/.env", atomically: true, encoding: .utf8)
    let health = try await w.c.call(DatabaseStatus(worktreeId: wt.id))
    #expect(health.map(\.state) == [.unknown] && health.first?.reason == "Kelp connects when you open it.")
}

/// Removing a project forgets the passwords of the databases added to it by hand.
@Test func removingAProjectForgetsItsDatabasesPasswords() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let db = DatabaseInfo(name: "prod", engine: .postgres, host: "db.example.com", port: 5432, database: "shop")
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: db, password: "s3cret"))
    let account = Databases.account(w.repo.id + "/prod")
    #expect(Keychain.get(account) == "s3cret")
    _ = try await w.c.call(RepoRemove(id: w.repo.id))
    #expect(Keychain.get(account) == nil)
}

/// The user's own reads (a page, a count) keep no rows, so they don't push out the rows a change still asked about
/// left in its trial.
@Test func theUsersReadsDontPushOutAnAskedChangesRows() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    _ = try shopDB(in: wt.path)
    let dbs = w.d.workspaces.databases
    let asked = DatabaseRun(
        id: "asked", database: "shop", sql: "UPDATE orders SET a = 1", session: "s", at: Date(), state: .asks)
    dbs.note(wt.id, asked, result: QueryResult(id: "asked", columns: ["id"], rows: [["1"]], total: 1, ms: 0))
    for _ in 0..<(Databases.keptResults + 5) {
        _ = try await w.c.call(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT count(*) FROM orders"))
    }
    #expect(dbs.result(wt.id, "asked")?.rows == [["1"]])
}

/// A server that doesn't answer is said so, with how to start one a compose file runs.
@Test func aDatabaseThatDoesntAnswerSaysHowToStartIt() async {
    let db = DatabaseInfo(name: "app_dev", engine: .postgres, source: "compose.yaml", host: "localhost", port: 5499)
    let said = DatabaseFailure.failed(
        "app_dev doesn't answer at postgres://localhost:5499/. Is it running? docker compose up -d starts what "
            + "compose.yaml runs.")
    let c = DatabaseConnection(database: db)
    await #expect(throws: said) {
        try await DatabaseEngines.explained(c) { () async throws -> Int in
            throw DatabaseFailure.failed("connection to server at \"localhost\", port 5499 failed: Connection refused")
        }
    }
    // Kelp's own client, at a port nothing listens on, says it the same way
    await #expect(throws: said) {
        try await DatabaseEngines.explained(c) { try await PostgresWire.read(c, "SELECT 1", timeout: 5) }
    }
}

/// A remote project's files are printed on its host by one shell line and read back here: run by this Mac's shell, in a
/// folder with a compose file and a .env, it finds both (and no SQLite file, which can't be opened from here).
@Test func aRemoteProjectsFilesAreReadInOneGo() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir + "/db", withIntermediateDirectories: true)
    try "services:\n  db:\n    image: postgres:16\n    ports:\n      - \"5432:5432\"\n".write(
        toFile: dir + "/compose.yaml", atomically: true, encoding: .utf8)
    try "DATABASE_URL=mysql://app:pw@localhost/shop\n".write(toFile: dir + "/.env", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: dir + "/api", withIntermediateDirectories: true)
    try "DATABASE_URL=postgres://u@localhost:5433/api\n".write(   // a monorepo's part, one level down
        toFile: dir + "/api/.env", atomically: true, encoding: .utf8)
    try Data("SQLite format 3\0".utf8).write(to: URL(fileURLWithPath: dir + "/db/x.sqlite3"))
    let out = try Subprocess.run(
        ["/bin/sh", "-c", DatabaseFind.remoteScript(dir)], cwd: "/", env: ["PATH": "/usr/bin:/bin"], timeLimit: 10)
    let found = DatabaseFind.parse(remote: String(decoding: out.stdout, as: UTF8.self), root: dir)
    #expect(found.map(\.database.engine) == [.postgres, .mysql, .postgres])
    #expect(found.map(\.database.source) == ["compose.yaml", ".env", "api/.env"] && found[1].password == "pw")
    #expect(DatabaseFind.find(in: dir).map(\.database.source) == ["compose.yaml", ".env", "api/.env", "db/x.sqlite3"])
}

/// A branch's workspace sees its project's SQLite file (untracked, it stays in the project's folder) until it gets a
/// copy of its own, at the same place in its folder: a change there leaves the project's alone.
@Test func aBranchGetsItsOwnCopyOfASQLiteDatabase() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let main = try await firstWorkspace(w)
    let original = try shopDB(in: main.path)
    let branch = try await workspace(w, "fix/orders")
    let seen = try #require(try await w.c.call(DatabaseList(worktreeId: branch.id)).first)
    #expect(seen.name == "shop" && seen.path == original)

    let copy = try await w.c.call(DatabaseCopy(worktreeId: branch.id, database: "shop"))
    #expect(copy.name == "shop" && copy.path == branch.path + "/db/shop.sqlite3")
    #expect(try await w.c.call(DatabaseList(worktreeId: branch.id)).first?.path == copy.path)
    _ = try await w.c.call(DatabaseQuery(worktreeId: branch.id, database: "shop", sql: "DELETE FROM orders"))
    #expect(try count(copy.path ?? "", "SELECT count(*) FROM orders") == 0)
    #expect(try count(original, "SELECT count(*) FROM orders") == 3)
    // Its own copied again: beside it, under the branch's name; and once that's there, no more.
    let again = try await w.c.call(DatabaseCopy(worktreeId: branch.id, database: "shop"))
    #expect(again.name == "shop_fix_orders" && again.path == branch.path + "/db/shop_fix_orders.sqlite3")
    await #expect(throws: RPCError.self) {
        try await w.c.call(DatabaseCopy(worktreeId: branch.id, database: "shop"))
    }
    // In the project's own folder: beside it, under the branch's name.
    let beside = try await w.c.call(DatabaseCopy(worktreeId: main.id, database: "shop"))
    #expect(beside.name == "shop_main" && beside.path == main.path + "/db/shop_main.sqlite3")
    #expect(Databases.slug("Feature/ÜBER-orders#2") == "feature_über_orders_2")
}

/// A real agent's screen and hooks go on while its command waits (its spinner reads as working): Kelp's question stays
/// asked until it's answered, and the agent's Stop (its turn, and the command, are over) ends it unanswered.
@Test func aChangeStaysAskedWhileTheAgentLooksBusy() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try shopDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let dbs = w.d.workspaces.databases
    let update = DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET note = 'y'")
    func asked() async throws -> Bool {
        try await waitFor { try w.d.store.session(agent.id)?.summary.hasPrefix("Allow changing") == true }
    }

    let first = Task { try await dbs.query(update, origin: agent.id) }
    #expect(try await asked())
    _ = try await w.c.call(SessionHook(id: agent.id, event: "working", hookName: "PreToolUse"))
    // What the ticker would do next to its status, done now: the hook has been taken (the call answered after it)
    let live = try #require(w.d.sessions.existing(agent.id))
    for _ in 0..<3 { live.tick() }
    let session = try #require(try w.d.store.session(agent.id))
    #expect(session.status == .waiting && session.summary == "Allow changing 3 rows of orders in shop?")
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: session.summary)))
    #expect(try await first.value.changed == 3)
    #expect(try count(path, "SELECT count(*) FROM orders WHERE note = 'y'") == 3)

    let second = Task { try await dbs.query(update, origin: agent.id) }
    #expect(try await asked())
    _ = try await w.c.call(SessionHook(id: agent.id, event: "done", hookName: "Stop"))
    await #expect(throws: RPCError.self) { try await second.value }
    #expect(try await waitFor { try w.d.store.session(agent.id)?.summary.hasPrefix("Allow") == false })
}

/// ~/.pgpass as libpq reads it: the first line that fits, `*` for any, `localhost` for this Mac's addresses, escapes.
@Test func pgpassLinesFitAsLibpqReadsThem() {
    let file = """
        # comment
        db.example.com:5432:app:app:remote
        localhost:55432:*:app:local\\:pw
        *:*:*:*:any
        """
    #expect(PgPass.match(file, host: "127.0.0.1", port: 55432, database: "x", user: "app") == "local:pw")
    #expect(PgPass.match(file, host: "db.example.com", port: 5432, database: "app", user: "app") == "remote")
    #expect(PgPass.match(file, host: "other", port: 1, database: "d", user: "u") == "any")
    #expect(PgPass.match("h:1:d:u:p", host: "h", port: 2, database: "d", user: "u") == nil)
}

/// A DuckDB file is found by its first bytes and spoken to through `duckdb`: NULL apart from "", its keys, a change
/// counted through RETURNING, and an agent's read held to read-only. Where duckdb is installed (not on CI).
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/duckdb")))
func aDuckDBFileIsReadAndChangedThroughDuckDB() async throws {
    let w = try await world(agents: [AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = wt.path + "/data/shop.duckdb"
    try FileManager.default.createDirectory(atPath: wt.path + "/data", withIntermediateDirectories: true)
    let made = try await Subprocess.run(
        [
            "/opt/homebrew/bin/duckdb", path, "-c",
            "CREATE TABLE users (id INT PRIMARY KEY); CREATE TABLE orders (id INT PRIMARY KEY, "
                + "user_id INT REFERENCES users(id), note VARCHAR); INSERT INTO users VALUES (1); "
                + "INSERT INTO orders VALUES (1, 1, NULL), (2, 1, ''), (3, 1, 'x');"
        ], cwd: "/", env: ["HOME": NSHomeDirectory()], timeLimit: 30)
    #expect(made.status == 0)
    let list = try await w.c.call(DatabaseList(worktreeId: wt.id))
    #expect(list.map(\.name) == ["shop"] && list.first?.engine == .duckdb && list.first?.source == "data/shop.duckdb")

    let orders = try #require(
        try await w.c.call(DatabaseSchemaRead(worktreeId: wt.id, database: "shop", table: "orders")).tables.first)
    #expect(orders.columns.map(\.name) == ["id", "user_id", "note"] && orders.rows == 3)
    #expect(orders.columns[0].primary && orders.columns[1].references == "users.id")

    let read = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT id, note FROM orders ORDER BY id"))
    #expect(read.columns == ["id", "note"] && read.rows == [["1", nil], ["2", ""], ["3", "x"]])
    let change = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET note = 'y' WHERE id > 1"))
    #expect(change.changed == 2)
    // A change allowed for fewer rows than it changes now: none changed; allowed for as many, made, its rows kept.
    #expect(throws: DatabaseEngines.notAsAllowed(3, 2)) {
        try DuckDBRun.write(path, "UPDATE orders SET note = 'h'", allowed: 2)
    }
    let held = try DuckDBRun.write(path, "UPDATE orders SET note = 'h' WHERE id > 1", allowed: 2)
    #expect(held.changed == 2 && held.rows.count == 2)
    let notes = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT count(*) FROM orders WHERE note = 'h'"))
    #expect(notes.rows == [["2"]])
    // The tab's edits: one transaction, the rows each changed counted (DuckDB prints no count of its own).
    let saved = try await w.c.call(
        DatabaseApply(
            worktreeId: wt.id, database: "shop",
            statements: ["UPDATE orders SET note = 'z' WHERE id = 1", "DELETE FROM orders WHERE id = 99"]))
    #expect(saved.changed == 1)
    await #expect(throws: RPCError.self) {
        try await w.c.call(
            DatabaseApply(
                worktreeId: wt.id, database: "shop",
                statements: ["UPDATE orders SET note = 'w' WHERE id = 1", "INSERT INTO orders VALUES (1, 1, 'dup')"]))
    }
    let after = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT note FROM orders WHERE id = 1"))
    #expect(after.rows == [["z"]])
    // -safe: no file but this one, and no dot-command reaching past it.
    #expect(throws: DatabaseFailure.self) {
        try DuckDBRun.read(path, "SELECT * FROM read_csv('/etc/passwd')", timeout: 10)
    }
    #expect(throws: DatabaseFailure.self) {
        _ = try DuckDBRun.run(path, readOnly: true, [".shell echo ran"], timeout: 10)
    }
    // An answer past what Kelp reads is refused, not read as no rows.
    #expect(throws: DatabaseFailure.self) {
        try DuckDBRun.read(path, "SELECT repeat('x', 1000000) FROM range(40)", timeout: 30)
    }

    var db = try #require(list.first)
    db.access = .read
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: db))
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    await #expect(throws: RPCError.self) {
        try await w.d.workspaces.databases.query(
            DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "DELETE FROM orders"), origin: agent.id)
    }
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first?.state == .refused)
}

/// A runaway SQLite read stops at its time limit, its slot free again.
@Test func aSQLiteReadStopsAtItsTimeLimit() throws {
    let path = try shopDB(in: NSTemporaryDirectory() + "kelp-slow-\(UUID().uuidString)")
    let started = Date()
    #expect(throws: DatabaseFailure.failed("It took more than 0 s.")) {
        try SQLiteRun.read(
            path, "WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM r) SELECT count(*) FROM r",
            timeout: 0.3)
    }
    #expect(Date().timeIntervalSince(started) < 60)   // stopped, not run to the end (it has none)
}

/// MySQL commits a transaction before DDL and runs it outside: a DROP is never sent as a read nor tried in a
/// transaction, so an agent held to read-only is refused before anything reaches the server (here, one that isn't up).
@Test func mySQLsDDLIsAChangeNeverTriedAsARead() async throws {
    #expect(SQLText.mayTryAsRead("SELECT 1", .mysql) && SQLText.mayTryAsRead("DROP TABLE t", .postgres))
    #expect(!SQLText.mayTryAsRead("DROP TABLE t", .mysql) && !SQLText.mayTryAsRead("CALL wipe()", .mysql))
    #expect(SQLText.mayTry("UPDATE t SET a = 1", .mysql) && !SQLText.mayTry("ALTER TABLE t ADD c INT", .mysql))
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let db = DatabaseInfo(name: "shop", engine: .mysql, host: "127.0.0.1", port: 1, database: "shop", access: .read)
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: db))
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    do {
        _ = try await w.d.workspaces.databases.query(
            DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "DROP TABLE orders"), origin: agent.id)
        Issue.record("an agent's DROP ran")
    } catch let error as RPCError {
        #expect(error.isRefusal, "refused as a change, not tried: \(error.message)")
    }
}

/// "All my projects": kept apart from every project, opened by the user, unseen by agents until used in a project,
/// which copies it there with its password.
@Test func theLibraryIsTheUsersUntilUsedInAProject() async throws {
    let w = try await world(agents: [AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try shopDB(in: NSTemporaryDirectory() + "kelp-lib-\(UUID().uuidString)")
    let saved = try await w.c.call(
        DatabaseSave(
            worktreeId: wt.id, database: DatabaseInfo(name: "shop", engine: .sqlite, path: path, access: .free),
            library: true))
    #expect(saved.source == nil)
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).isEmpty)   // not the project's
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).library?.map(\.name) == ["shop"])
    let read = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT count(*) FROM orders"))
    #expect(read.rows == [["3"]])   // the user opens it from any workspace

    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let dbs = w.d.workspaces.databases
    await #expect(throws: RPCError.self) {
        try await dbs.query(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT 1"), origin: agent.id)
    }
    _ = try await w.c.call(DatabaseUse(worktreeId: wt.id, name: "shop"))
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).map(\.name) == ["shop"])
    let seen = try await dbs.query(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT count(*) FROM users"), origin: agent.id)
    #expect(seen.rows == [["1"]])
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "shop", library: true))
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).library == [])
}

/// The sheet's check: what's there, or the server's words; a container's published port read from `docker ps`.
@Test func theSheetChecksWhatIsTypedAndReadsDockersPorts() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try shopDB(in: NSTemporaryDirectory() + "kelp-check-\(UUID().uuidString)")
    let ok = try await w.c.call(
        DatabaseCheck(worktreeId: wt.id, database: DatabaseInfo(name: "x", engine: .sqlite, path: path)))
    #expect(ok.version == "SQLite" && ok.tables == 2 && ok.databases.isEmpty)
    await #expect(throws: RPCError.self) {
        try await w.c.call(
            DatabaseCheck(
                worktreeId: wt.id, database: DatabaseInfo(name: "x", engine: .postgres, host: "localhost", port: 5499)))
    }
    // Docker's running ones: whatever runs on this Mac (none on CI), each with an address and no password
    let running = try await w.c.call(DatabaseContainers())
    #expect(running.allSatisfy { $0.database.host == "localhost" && $0.database.port != nil })
    #expect(Databases.published("0.0.0.0:55432->5432/tcp, [::]:55432->5432/tcp", 5432) == 55432)
    #expect(Databases.published("5432/tcp", 5432) == nil)
    #expect(DatabaseInfo.Engine(image: "postgis/postgis:16-3.4") == .postgres)
    #expect(DatabaseInfo.Engine(image: "mariadb:10.11") == .mysql && DatabaseInfo.Engine(image: "redis:7") == nil)
    #expect(DatabaseInfo.Engine(image: "localhost:5000/bitnami/postgresql:16") == .postgres)
}

/// An IDE's connections in the project are found as compose's are: DataGrip's .idea, VS Code's SQLTools.
@Test func anIDEsConnectionsInTheProjectAreFound() throws {
    let root = NSTemporaryDirectory() + "kelp-ide-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/.idea", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/.vscode", withIntermediateDirectories: true)
    try """
    <project><component name="DataSourceManagerImpl"><data-source name="dev" uuid="u">
    <driver-ref>postgresql</driver-ref><jdbc-url>jdbc:postgresql://localhost:5433/app_dev</jdbc-url>
    </data-source></component></project>
    """.write(toFile: root + "/.idea/dataSources.xml", atomically: true, encoding: .utf8)
    try """
    {
      // mine
      "sqltools.connections": [
        { "name": "shop", "driver": "MySQL", "server": "127.0.0.1", "port": 3306, "database": "shop",
          "username": "root", "password": "pw", },
      ],
    }
    """.write(toFile: root + "/.vscode/settings.json", atomically: true, encoding: .utf8)
    let found = DatabaseFind.find(in: root)
    #expect(found.map(\.database.name) == ["dev", "shop"])
    #expect(found[0].database.port == 5433 && found[0].database.source == ".idea/dataSources.xml")
    #expect(found[1].database.engine == .mysql && found[1].password == "pw")
    #expect(DatabaseFind.matters(root + "/.idea/dataSources.xml"))
}

/// Compose's ports written as a flow list on one line count as much as a block list.
@Test func composePortsOnOneLineAreRead() {
    let compose = """
        services:
          db:
            image: postgres:16-alpine
            ports: ["55432:5432", "9000:9000"]
            environment:
              POSTGRES_PASSWORD: secret
        """
    let found = DatabaseFind.parse([("compose.yaml", compose)], root: "/p")
    #expect(found.first?.database.port == 55432 && found.first?.database.host == "localhost")
}

/// The panel's dots: a file there answers, one gone is down with why; a server nothing listens for is down too, and
/// only a compose service can be started.
@Test func eachDatabaseSaysWhetherItAnswers() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    _ = try shopDB(in: wt.path)
    _ = try await w.c.call(
        DatabaseSave(worktreeId: wt.id, database: DatabaseInfo(name: "gone", engine: .sqlite, path: "/tmp/nope.db")))
    _ = try await w.c.call(
        DatabaseSave(
            worktreeId: wt.id,
            database: DatabaseInfo(name: "pg", engine: .postgres, host: "localhost", port: 5499, database: "x")))
    let dots = try await w.c.call(DatabaseStatus(worktreeId: wt.id))
    #expect(dots.map(\.name) == ["shop", "gone", "pg"])
    #expect(dots.map(\.state) == [.ok, .down, .down] && dots[1].reason == "The file isn't there.")
    await #expect(throws: RPCError.self) { try await w.c.call(DatabaseStart(worktreeId: wt.id, name: "pg")) }
}

/// The tab's edits are all or none: one that fails leaves the others undone.
@Test func theUsersEditsAreAllOrNone() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try shopDB(in: wt.path)
    await #expect(throws: RPCError.self) {
        try await w.c.call(
            DatabaseApply(
                worktreeId: wt.id, database: "shop",
                statements: ["UPDATE orders SET status = 'x' WHERE id = 1", "INSERT INTO nowhere VALUES (1)"]))
    }
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'x'") == 0)
    let done = try await w.c.call(
        DatabaseApply(
            worktreeId: wt.id, database: "shop",
            statements: ["UPDATE orders SET status = 'x' WHERE id = 1", "DELETE FROM orders WHERE id = 3"]))
    let left = try count(path, "SELECT count(*) FROM orders")
    #expect(done.changed == 2 && left == 2)
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.map(\.state) == [.done, .failed])
}

/// A view is listed as one, apart from the tables.
@Test func aViewIsListedAsAView() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try shopDB(in: wt.path)
    try await DatabaseQueue(path: path).write {
        try $0.execute(sql: "CREATE VIEW paid AS SELECT * FROM orders WHERE status = 'paid'")
    }
    let schema = try await w.c.call(DatabaseSchemaRead(worktreeId: wt.id, database: "shop"))
    #expect(schema.tables.first { $0.name == "paid" }?.kind == "view")
    #expect(schema.tables.first { $0.name == "orders" }?.kind == nil)
}
