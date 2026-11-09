import Agents
import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Daemon

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])

// MARK: SQL text

/// A ";" inside quotes, a dollar-quoted body or a comment doesn't split; an empty last statement is dropped.
@Test func statementsSplitOnlyOutsideQuotesAndComments() throws {
    #expect(SQLText.statements("SELECT ';' AS a; SELECT 2;") == ["SELECT ';' AS a", "SELECT 2"])
    #expect(SQLText.statements("SELECT 1 -- ; not here\n") == ["SELECT 1 -- ; not here"])
    #expect(SQLText.statements("DO $$ BEGIN PERFORM 1; END $$;").count == 1)
    #expect(SQLText.statements("SELECT /* ; */ 1; -- only a comment").count == 1)
    #expect(SQLText.statements("SELECT 'it''s; fine'").count == 1)
    #expect(try SQLText.single("  UPDATE t SET a = 1;  ") == "UPDATE t SET a = 1")
    #expect(throws: DatabaseFailure.self) { try SQLText.single("COMMIT; DELETE FROM users") }
    #expect(throws: DatabaseFailure.self) { try SQLText.single("\\! rm -rf ~") }
    #expect(throws: DatabaseFailure.self) { try SQLText.single("-- nothing") }
    #expect(SQLText.verb("/* why */ with x as (select 1) select * from x") == "WITH")
    #expect(SQLText.returning("UPDATE t SET a = 1") == "UPDATE t SET a = 1 RETURNING *")
    #expect(SQLText.returning("DELETE FROM t RETURNING id") == nil)
    #expect(SQLText.returning("SELECT 1") == nil)
}

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

@Test func envURLsAreFoundAndAProductionOneIsReadOnly() {
    let text = """
        # the app's
        DATABASE_URL="postgres://app:p%40ss@localhost:5432/app_dev"
        export ANALYTICS_DB_URL=mysql://ro@db.example.com/analytics
        SECRET_KEY=abc
        """
    let found = DatabaseFind.unique(DatabaseFind.env(text, source: ".env", root: "/p"))
    #expect(found.count == 2)
    #expect(found[0].database.name == "app_dev" && found[0].password == "p@ss" && !found[0].database.production)
    #expect(found[1].database.production && found[1].database.access == .read && found[1].database.port == 3306)
    let prod = DatabaseFind.unique(
        DatabaseFind.env("DATABASE_URL=postgres://u@localhost/shop", source: ".env.production", root: "/p"))
    #expect(prod.first?.database.production == true)
    let sqlite = DatabaseFind.env("DATABASE_URL=file:./dev.db", source: ".env", root: "/p")
    #expect(sqlite.first?.database.path == "/p/dev.db" && sqlite.first?.database.name == "dev")
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
    let rows = PostgresRun.section("id,name,note\n1,\"a, b\",\n2,\"\",\"say \"\"hi\"\"\"\n")
    #expect(rows.columns == ["id", "name", "note"])
    #expect(rows.rows == [["1", "a, b", nil], ["2", "", "say \"hi\""]])
    #expect(rows.total == 2)
    #expect(PostgresRun.section("UPDATE 1204\n").changed == 1204)
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
    let kept = try await w.c.call(DatabaseResultRead(worktreeId: wt.id, id: read.id))
    #expect(kept?.rows.count == 3)   // the tab gets them all

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
/// rows in shop?"), and runs once the user allows it. Denied, nothing changes and the agent is told so.
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
            return run != nil
        }
        return (try w.d.store.session(agent.id)?.summary ?? "", run?.id ?? "")
    }

    let first = ask()
    let (question, firstRun) = try await asked()
    #expect(question == "Allow changing 2 rows in shop?")
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
    let connection = try w.d.workspaces.databases.connection(wt.id, "prod", agent: false)
    #expect(connection.password == "s3cret")
    let sent = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
    #expect(!sent.contains("s3cret"))
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "prod"))
    #expect(Keychain.get(Databases.account(w.repo.id + "/prod")) == nil)
}

/// A server that doesn't answer is said so, with how to start one a compose file runs.
@Test func aDatabaseThatDoesntAnswerSaysHowToStartIt() {
    let db = DatabaseInfo(name: "app_dev", engine: .postgres, source: "compose.yaml", host: "localhost", port: 5499)
    #expect(
        throws: DatabaseFailure.failed(
            "app_dev doesn't answer at postgres://localhost:5499/. Is it running? docker compose up -d starts what "
                + "compose.yaml runs.")
    ) {
        try DatabaseEngines.explained(DatabaseConnection(database: db)) { () throws -> Int in
            throw DatabaseFailure.failed("connection to server at \"localhost\", port 5499 failed: Connection refused")
        }
    }
}
