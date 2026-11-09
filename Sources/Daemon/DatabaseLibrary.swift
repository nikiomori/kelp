import Core
import Foundation
import GRDB

/// One of "All my projects" (`databaseLibrary` table), keyed by name.
struct LibraryDatabase: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "databaseLibrary"
    var id: String, json: String

    var database: DatabaseInfo? {
        Log.store.attempt("reading the library's database \(id)") {
            try JSONDecoder().decode(DatabaseInfo.self, from: Data(json.utf8))
        }
    }

    init(_ database: DatabaseInfo) throws {
        id = database.name
        json = String(decoding: try JSONEncoder().encode(database), as: UTF8.self)
    }
}

/// "All my projects": databases the user keeps apart from any project (added so, or imported from another app). No
/// agent sees one until it's used in a project (`use`), which copies it there. Their passwords are kept as
/// "db:/<name>". And what the Add Database sheet asks of the daemon: a check of what's typed, the servers running in
/// Docker.
extension Databases {
    static let libraryRepo = ""

    func library() throws -> [DatabaseInfo] {
        try store.db.read { try LibraryDatabase.fetchAll($0) }.compactMap(\.database)
            .sorted { ($0.group ?? "", $0.name) < ($1.group ?? "", $1.name) }
    }

    func libraryConnection(_ name: String) throws -> DatabaseConnection? {
        guard let entry = try store.db.read({ try LibraryDatabase.fetchOne($0, key: name) }), let db = entry.database
        else { return nil }
        let account = Self.account(Self.libraryRepo + "/" + name)
        return DatabaseConnection(database: db, password: Keychain.get(account), account: account)
    }

    func saveInLibrary(_ worktreeId: String, _ database: DatabaseInfo, password: String?) throws -> DatabaseInfo {
        var db = database
        db.name = db.name.trimmingCharacters(in: .whitespaces)
        db.source = nil
        guard !db.name.isEmpty, !db.name.contains("/") else {
            throw RPCError.invalidParams("Give it a name without /.")
        }
        let entry = try LibraryDatabase(db)
        try store.db.write { try entry.save($0) }
        let account = Self.account(Self.libraryRepo + "/" + db.name)
        if let password {
            if password.isEmpty { Keychain.delete(account) } else { try Keychain.set(password, account: account) }
        }
        touch(worktreeId)
        return db
    }

    /// Copied into the workspace's project with its password: from now on its agents see it.
    func use(_ worktreeId: String, _ name: String, access: DatabaseInfo.Access?) throws -> DatabaseInfo {
        guard let mine = try libraryConnection(name) else {
            throw RPCError.invalidParams("No \(name) in All my projects.")
        }
        var db = mine.database
        db.access = access ?? (db.host.map(DatabaseFind.isLocal) == false ? .read : db.access)
        db.production = db.production || (db.host.map { !DatabaseFind.isLocal($0) } ?? false) && db.ssh == nil
        db.group = nil
        return try save(worktreeId, db, password: mine.password)
    }

    // MARK: The sheet's check

    func check(_ q: DatabaseCheck) async throws -> DatabaseCheckResult {
        let (wid, name) = (q.worktreeId, q.database.name)
        var c = DatabaseConnection(database: q.database, password: q.password)
        if c.password == nil {   // the one kept for it, when it's being edited
            c.password = try await offloads.run { [self] in
                do { return try connection(wid, name, agent: false).password } catch { return nil }
            }
        }
        let started = Date()
        let typed = c
        let near = try await offloads.run { [self] in try reach(typed, wid) }
        do {
            let schema = try await DatabaseEngines.schema(near, table: nil, off: offloads)
            var version = DatabaseLook.engine(near.database.engine), databases: [String] = []
            switch near.database.engine {
            case .postgres where near.database.host != nil:
                version = try await PostgresWire.version(near)
                databases = try await PostgresWire.databases(near)
            case .mysql where near.database.host != nil:
                version = try await MySQLWire.version(near)
                databases = try await MySQLWire.databases(near)
            case .appwrite:
                version = try await AppwriteWire.version(near)
                databases = try await AppwriteWire.databases(near)
            default: break
            }
            return DatabaseCheckResult(
                version: version, tables: schema.tables.count, databases: databases,
                ms: Int(Date().timeIntervalSince(started) * 1000))
        } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
    }

    // MARK: Docker

    /// Running containers of Postgres, MySQL or MariaDB images that publish their port, as this Mac reaches them.
    /// Docker not running: none.
    func containers() async throws -> [RunningDatabase] {
        try await offloads.run {
            guard let docker = Self.docker(),
                let listed = Subprocess.printed(
                    [docker, "ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}"],
                    path: "/usr/local/bin:/usr/bin:/bin", timeout: 10)
            else { return [] }
            return listed.split(whereSeparator: \.isNewline).compactMap { line in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count == 4, let engine = Self.engine(image: f[2]) else { return nil }
                let inside = engine == .postgres ? 5432 : 3306
                guard let port = Self.published(f[3], inside) else { return nil }
                let env = Self.environment(docker, f[0])
                var db = DatabaseInfo(name: f[1], engine: engine, host: "localhost", port: port)
                if engine == .postgres {
                    db.user = env["POSTGRES_USER"] ?? "postgres"
                    db.database = env["POSTGRES_DB"] ?? db.user
                } else {
                    db.user = env["MYSQL_USER"] ?? env["MARIADB_USER"] ?? "root"
                    db.database = env["MYSQL_DATABASE"] ?? env["MARIADB_DATABASE"]
                }
                db.name = db.database ?? f[1]
                return RunningDatabase(container: f[0], name: f[1], image: f[2], database: db)
            }
        }
    }

    /// The password a container's environment gives its user: what `db.save` keeps for one picked from `containers`.
    func containerPassword(_ container: String, _ engine: DatabaseInfo.Engine) throws -> String? {
        guard let docker = Self.docker() else { throw RPCError.invalidParams("Docker isn't installed.") }
        let env = Self.environment(docker, container)
        if engine == .postgres { return env["POSTGRES_PASSWORD"] }
        let root = (env["MYSQL_USER"] ?? env["MARIADB_USER"]) == nil
        return root
            ? env["MYSQL_ROOT_PASSWORD"] ?? env["MARIADB_ROOT_PASSWORD"]
            : env["MYSQL_PASSWORD"] ?? env["MARIADB_PASSWORD"]
    }

    static func docker() -> String? {
        do {
            return try DatabaseEngines.client(
                "docker",
                also: ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin"])
        } catch { return nil }
    }

    static func engine(image: String) -> DatabaseInfo.Engine? {
        let name = image.split(separator: ":").first.map { $0.split(separator: "/").last.map(String.init) ?? "" } ?? ""
        if ["postgres", "postgis", "timescaledb", "timescaledb-ha", "pgvector"].contains(name) { return .postgres }
        if ["mysql", "mariadb", "percona-server"].contains(name) { return .mysql }
        return nil
    }

    /// "0.0.0.0:55432->5432/tcp, [::]:55432->5432/tcp": the port on this Mac for `inside`.
    static func published(_ ports: String, _ inside: Int) -> Int? {
        for part in ports.split(separator: ",") where part.hasSuffix("->\(inside)/tcp") {
            let host = part.split(separator: "-").first?.split(separator: ":").last
            if let port = host.flatMap({ Int($0) }) { return port }
        }
        return nil
    }

    private static func environment(_ docker: String, _ container: String) -> [String: String] {
        let printed =
            Subprocess.printed(
                [docker, "inspect", "--format", "{{range .Config.Env}}{{println .}}{{end}}", container],
                path: "/usr/local/bin:/usr/bin:/bin", timeout: 10) ?? ""
        var env: [String: String] = [:]
        for line in printed.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return env
    }
}

extension DatabaseCheck: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> DatabaseCheckResult { try await dbs.check(self) }
}

extension DatabaseContainers: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> [RunningDatabase] { try await dbs.containers() }
}

extension DatabaseUse: Handled {
    func handle(_ dbs: Databases) throws -> DatabaseInfo { try dbs.use(worktreeId, name, access: access) }
}

/// An engine's name as the sheet's check says it.
enum DatabaseLook {
    static func engine(_ e: DatabaseInfo.Engine) -> String {
        switch e {
        case .sqlite: "SQLite"
        case .postgres: "Postgres"
        case .mysql: "MySQL"
        case .duckdb: "DuckDB"
        case .appwrite: "Appwrite"
        }
    }
}
