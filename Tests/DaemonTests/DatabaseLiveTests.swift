import Agents
import Core
import Foundation
import TestSupport
import Testing

@testable import Daemon

// Against real servers, when asked for: KELP_TEST_POSTGRES=<port> (a Postgres on localhost, user app, password secret,
// database app_dev, with the orders and users tables of `DatabaseTests` and `kinds`, one row of each type the test
// lists), KELP_TEST_MYSQL=<port> (a MariaDB or MySQL on localhost, root password root, database shop),
// KELP_TEST_COMPOSE=1 (Docker with the images postgres:16-alpine and mariadb:10.11 on this Mac). Off by default: CI
// has neither.

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])
private let env = ProcessInfo.processInfo.environment

/// Kelp's own Postgres client: the schema with its keys, rows with NULL apart from "", each type as psql writes it, an
/// agent's change tried (RETURNING), asked, allowed and made; one statement only; read only refuses; the server's own
/// error comes through.
@Test(.enabled(if: env["KELP_TEST_POSTGRES"] != nil)) func postgresThroughItsOwnClient() async throws {
    let port = env["KELP_TEST_POSTGRES"] ?? ""
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    try "DATABASE_URL=postgres://app:secret@localhost:\(port)/app_dev\n".write(
        toFile: wt.path + "/.env", atomically: true, encoding: .utf8)
    let dbs = w.d.workspaces.databases
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).map(\.name) == ["app_dev"])
    _ = try await w.c.call(   // as it was seeded, whatever a run before left
        DatabaseQuery(
            worktreeId: wt.id, database: "app_dev",
            sql: "UPDATE orders SET note = CASE id WHEN 1 THEN NULL WHEN 2 THEN '' ELSE 'x' END"))

    let schema = try await w.c.call(DatabaseSchemaRead(worktreeId: wt.id, database: "app_dev", table: "orders"))
    let orders = try #require(schema.tables.first)
    #expect(orders.columns.map(\.name) == ["id", "user_id", "status", "note"])
    #expect(orders.columns[0].primary && orders.columns[1].references == "users.id" && !orders.columns[2].nullable)
    #expect(orders.indexes.contains { $0.hasPrefix("orders_status") } && orders.rows == 3)
    #expect(orders.comment == "Customer orders" && (orders.bytes ?? 0) > 0 && orders.kind == nil)
    let whole = try await w.c.call(DatabaseSchemaRead(worktreeId: wt.id, database: "app_dev"))
    #expect(whole.tables.first { $0.name == "paid_orders" }?.kind == "view" && whole.functions == ["add_one"])

    let read = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "SELECT id, note FROM orders ORDER BY id"))
    #expect(read.columns == ["id", "note"] && read.rows == [["1", nil], ["2", ""], ["3", "x"]])
    // Kelp speaks the protocol itself (binary values): each type written as psql writes it
    let kinds = try await w.c.call(DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "SELECT * FROM kinds"))
    #expect(
        kinds.rows.first == [
            "42.50", "-0.000123", "1.5", "2026-11-09 03:51:49.12", "2026-11-09 03:51:49+00", "1999-12-31", "13:05:00.5",
            "1 year 2 mons 3 days 04:05:06", #"{"a": [1, 2]}"#, #"{"b":1}"#, "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
            "\\xdeadbeef", "{1,2,NULL}", #"{"a b",c}"#, "192.168.0.1/24", "t", "$12.34"
        ])
    let none = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "SELECT id, note FROM orders WHERE false"))
    #expect(none.columns == ["id", "note"] && none.rows.isEmpty)   // the columns of no rows

    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let change = DatabaseQuery(
        worktreeId: wt.id, database: "app_dev", sql: "UPDATE orders SET note = 'seen' WHERE status = 'pending'")
    let asked = Task { try await dbs.query(change, origin: agent.id) }
    var run: DatabaseRun?
    #expect(
        try await waitFor(15) {
            run = try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first { $0.state == .asks }
            return run != nil
        })
    #expect(run?.changed == 2)
    let preview = try await w.c.call(DatabaseResultRead(worktreeId: wt.id, id: run?.id ?? ""))
    #expect(preview?.rows.compactMap { $0.last ?? nil } == ["seen", "seen"])   // RETURNING *: as they'd be
    let question = try w.d.store.session(agent.id)?.summary ?? ""
    #expect(question == "Allow changing 2 rows in app_dev?")
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: question)))
    #expect(try await asked.value.changed == 2)
    let after = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "SELECT count(*) FROM orders WHERE note = 'seen'"))
    #expect(after.rows == [["2"]])
    _ = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "UPDATE orders SET note = 'x' WHERE id = 3"))

    await #expect(throws: RPCError.self) {
        try await dbs.query(
            DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "COMMIT; DELETE FROM orders"), origin: agent.id)
    }
    // The tab's edits in one transaction over Kelp's own connection: a failure undoes the ones before it.
    await #expect(throws: RPCError.self) {
        try await w.c.call(
            DatabaseApply(
                worktreeId: wt.id, database: "app_dev",
                statements: ["UPDATE orders SET note = 'gone' WHERE id = 3", "UPDATE nowhere SET x = 1"]))
    }
    let kept = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "SELECT note FROM orders WHERE id = 3"))
    #expect(kept.rows == [["x"]])
    // A copy for a branch: CREATE DATABASE … TEMPLATE, listed as one of its own; dropped again here.
    let copy = try await w.c.call(DatabaseCopy(worktreeId: wt.id, database: "app_dev"))
    #expect(copy.name == "app_dev_main" && copy.database == "app_dev_main")
    let copied = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: copy.name, sql: "SELECT count(*) FROM orders"))
    #expect(copied.rows == [["3"]])
    _ = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "DROP DATABASE app_dev_main"))
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: copy.name))

    var db = try #require(try await w.c.call(DatabaseList(worktreeId: wt.id)).first)
    db.access = .read
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: db))
    await #expect(throws: RPCError.self) {
        try await dbs.query(
            DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "DELETE FROM orders"), origin: agent.id)
    }
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first?.state == .refused)
    do {
        _ = try await w.c.call(DatabaseQuery(worktreeId: wt.id, database: "app_dev", sql: "SELECT * FROM nothing"))
        Issue.record("a missing table read without an error")
    } catch let error as RPCError {
        #expect(error.message.contains("\"nothing\" does not exist"))
    }
}

/// MySQL or MariaDB at a port: Kelp's own client reads, refuses a change in a read-only transaction, counts a trial's.
@Test(.enabled(if: env["KELP_TEST_MYSQL"] != nil)) func mysqlThroughItsOwnClient() async throws {
    let port = env["KELP_TEST_MYSQL"] ?? ""
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    try "DATABASE_URL=mysql://root:root@localhost:\(port)/shop\n".write(
        toFile: wt.path + "/.env", atomically: true, encoding: .utf8)
    func run(_ sql: String) async throws -> QueryResult {
        try await w.c.call(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: sql))
    }
    var ready = false
    _ = try await waitFor(60) {   // the server takes a few seconds after its container starts
        do { ready = try await run("SELECT 1").rows == [["1"]] } catch { ready = false }
        return ready
    }
    #expect(ready)
    _ = try await run("DROP TABLE IF EXISTS t")
    _ = try await run("CREATE TABLE t (id INT PRIMARY KEY, v VARCHAR(9), d DECIMAL(6,2))")
    #expect(try await run("INSERT INTO t VALUES (1, 'a\\tb', 4.5), (2, NULL, 0)").changed == 2)
    let rows = try await run("SELECT id, v, d FROM t ORDER BY id")
    #expect(rows.columns == ["id", "v", "d"] && rows.rows == [["1", "a\tb", "4.50"], ["2", nil, "0.00"]])
    #expect(try await w.c.call(DatabaseSchemaRead(worktreeId: wt.id, database: "shop")).tables.first?.name == "t")

    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let dbs = w.d.workspaces.databases
    let asked = Task {
        try await dbs.query(
            DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE t SET v = 'z'"), origin: agent.id)
    }
    var question = ""
    #expect(
        try await waitFor(15) {
            question = try w.d.store.session(agent.id)?.summary ?? ""
            return question.hasPrefix("Allow")
        })
    #expect(question == "Allow changing 2 rows in shop?")
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: question)))
    #expect(try await asked.value.changed == 2)
}

/// A compose project's Postgres and MariaDB with no port published: Kelp runs their clients in their containers.
@Test(.enabled(if: env["KELP_TEST_COMPOSE"] != nil)) func composeDatabasesThroughTheirContainers() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let compose = """
        services:
          pg:
            image: postgres:16-alpine
            environment:
              POSTGRES_USER: app
              POSTGRES_PASSWORD: secret
              POSTGRES_DB: app_dev
          my:
            image: mariadb:10.11
            environment:
              MARIADB_ROOT_PASSWORD: root
              MARIADB_DATABASE: shop
        """
    try compose.write(toFile: wt.path + "/compose.yaml", atomically: true, encoding: .utf8)
    let docker = "/usr/local/bin/docker", file = wt.path + "/compose.yaml"
    let up = try await Subprocess.run(
        [docker, "compose", "-f", file, "up", "-d", "--pull", "never"], cwd: wt.path,
        env: ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()], timeLimit: 120)
    #expect(up.status == 0, "\(String(decoding: up.stderr, as: UTF8.self))")
    defer { composeDown(file, in: wt.path) }
    let list = try await w.c.call(DatabaseList(worktreeId: wt.id))
    #expect(list.map(\.name) == ["app_dev", "shop"] && list.allSatisfy { $0.host == nil })

    /// The servers take a few seconds to take connections after their containers start.
    func ready(_ name: String, _ sql: String) async throws -> QueryResult? {
        var result: QueryResult?
        _ = try await waitFor(60) {
            do {
                result = try await w.c.call(DatabaseQuery(worktreeId: wt.id, database: name, sql: sql))
                return true
            } catch { return false }
        }
        return result
    }
    #expect(try await ready("app_dev", "SELECT 1 AS one, NULL AS nothing")?.rows == [["1", nil]])
    _ = try await ready("shop", "CREATE TABLE t (id INT PRIMARY KEY, v VARCHAR(9))")
    let inserted = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "INSERT INTO t VALUES (1, 'a\\tb'), (2, NULL)"))
    #expect(inserted.changed == 2)
    let rows = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT id, v FROM t ORDER BY id"))
    #expect(rows.columns == ["id", "v"] && rows.rows == [["1", "a\tb"], ["2", nil]])
    let tables = try await w.c.call(DatabaseSchemaRead(worktreeId: wt.id, database: "shop"))
    #expect(tables.tables.first?.columns.first?.primary == true)

    // An agent's change to MariaDB: read-only refuses it in its transaction, the trial counts it, Allow makes it.
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let dbs = w.d.workspaces.databases
    let asked = Task {
        try await dbs.query(
            DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE t SET v = 'z'"), origin: agent.id)
    }
    var question = ""
    #expect(
        try await waitFor(15) {
            question = try w.d.store.session(agent.id)?.summary ?? ""
            return question.hasPrefix("Allow")
        })
    #expect(question == "Allow changing 2 rows in shop?")
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: question)))
    #expect(try await asked.value.changed == 2)
}

/// Synchronous, for a `defer`: the test's containers and their volumes go.
private func composeDown(_ file: String, in dir: String) {
    _ = try? Subprocess.run(
        ["/usr/local/bin/docker", "compose", "-f", file, "down", "-v"], cwd: dir,
        env: ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()], timeLimit: 120)
}

/// A remote project's database, read only: KELP_TEST_REMOTE=host:/path of a project whose compose file runs a Postgres
/// that publishes its port on the host. Its files are read there, and one SELECT goes through a forwarded port.
@Test(.enabled(if: env["KELP_TEST_REMOTE"] != nil)) func aRemoteProjectsPostgresThroughAForwardedPort() async throws {
    let target = (env["KELP_TEST_REMOTE"] ?? "").split(separator: ":", maxSplits: 1).map(String.init)
    try #require(target.count == 2)
    let w = try await world()
    defer { w.d.stop() }
    let repo = try await w.c.call(RepoAddRemote(host: target[0], path: target[1]))
    let wt = try #require(try await w.c.call(WorktreeList()).first { $0.repoId == repo.id })
    let remote = try #require(w.d.remotes.of(wt.path))
    try remote.connect()   // listing never dials: the panel shows what an open connection reads
    defer {
        _ = try? Subprocess.run(
            [remote.ssh, "-o", "ControlPath=\(remote.controlDir)/%C", "-O", "exit", "--", remote.host], cwd: "/",
            env: [:], timeLimit: 10)
    }
    let postgres = try #require(try await w.c.call(DatabaseList(worktreeId: wt.id)).first { $0.engine == .postgres })
    #expect(postgres.host == "localhost" && postgres.source != nil)
    let one = try await w.c.call(
        DatabaseQuery(
            worktreeId: wt.id, database: postgres.name,
            sql: "SELECT 1 AS one, current_setting('transaction_read_only') AS ro"))
    #expect(one.rows == [["1", "on"]])
}
