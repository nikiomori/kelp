import Core
import Foundation

/// A database found in a project's files, with the password those files give it (never sent to a client).
struct FoundDatabase: Equatable {
    var database: DatabaseInfo
    var password: String?
    /// The compose service the database runs in, and its port inside the service, so its client can run inside that
    /// service's container.
    var service: (name: String, port: Int)?
    /// The folder that holds the database's source, when that isn't the workspace's folder. For a branch's workspace,
    /// it is the project's own folder.
    var root: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.database == rhs.database && lhs.password == rhs.password && lhs.service?.name == rhs.service?.name
            && lhs.service?.port == rhs.service?.port
    }
}

/// Finds where a project says its databases are: `.env` files (`DATABASE_URL` and the like), compose services of
/// postgres or mysql images, Rails' config/database.yml, and SQLite files near the top. It only reads files and never
/// connects.
/// Limit: YAML is read line by line (the shapes these files take, anchors written out as text), not parsed; values
/// from ERB aren't followed.
enum DatabaseFind {
    static let composeFiles = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
    static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "duckdb", "ddb"]
    /// Folders SQLite files are looked for in, beside the project's own top.
    static let sqliteFolders = ["db", "data", "prisma", "instance", "storage", "var"]

    /// Returns every database the files at `root` name, each name once.
    static func find(in root: String) -> [FoundDatabase] {
        let envs = FileManager.default.names(in: root).filter { $0 == ".env" || $0.hasPrefix(".env.") }.sorted()
        // The parts of a monorepo (api/, backend/) have their own compose files and .env, one level down.
        let parts = FileManager.default.names(in: root).filter { !$0.hasPrefix(".") && !skipped.contains($0) }.sorted()
            .flatMap { dir in
                (composeFiles + [".env"]).map { dir + "/" + $0 }
            }
        let files = (composeFiles + envs + ["config/database.yml", "prisma/schema.prisma"] + parts).compactMap { name in
            read(root, name).map { (name, $0) }
        }
        let found = parse(files, root: root) { read(root, $0) }
        return unique(found + ideConnections(in: root) + sqliteFiles(in: root))
    }

    /// Reads the connections an IDE keeps in the project: JetBrains' .idea/dataSources.xml (with the user from the
    /// .local.xml beside it) and VS Code's SQLTools in .vscode/settings.json. JetBrains keeps no password there, so
    /// ~/.pgpass or the user gives one.
    static func ideConnections(in root: String) -> [FoundDatabase] {
        let top = URL(fileURLWithPath: root)
        let idea = ImportReaders.dataSources(top.appendingPathComponent(".idea/dataSources.xml"), group: nil).map {
            var db = $0.imported.database
            db.source = ".idea/dataSources.xml"
            db.group = nil
            return FoundDatabase(database: db)
        }
        return idea + sqlTools(read(root, ".vscode/settings.json") ?? "")
    }

    /// Reads `sqltools.connections` from a VS Code settings file (JSON with comments and trailing commas).
    static func sqlTools(_ text: String) -> [FoundDatabase] {
        guard text.contains("sqltools.connections") else { return [] }
        let list = JSONC.object(text)?["sqltools.connections"] as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let engine = ImportReaders.engine(ImportReaders.string(entry["driver"])) else { return nil }
            let name = ImportReaders.nonEmpty(entry["name"]) ?? "sqltools"
            let source = ".vscode/settings.json"
            if engine.isFile {
                guard let path = ImportReaders.nonEmpty(entry["database"]) else { return nil }
                return FoundDatabase(database: DatabaseInfo(name: name, engine: engine, source: source, path: path))
            }
            let db = DatabaseInfo(
                name: name, engine: engine, source: source,
                host: ImportReaders.nonEmpty(entry["server"]) ?? "localhost",
                port: ImportReaders.int(entry["port"]), database: ImportReaders.nonEmpty(entry["database"]),
                user: ImportReaders.nonEmpty(entry["username"]))
            return FoundDatabase(database: db, password: ImportReaders.nonEmpty(entry["password"]))
        }
    }

    /// Reads the databases that the project's files name, given each file's path in the project: compose files, .env
    /// files, config/database.yml and prisma/schema.prisma. `more` reads another file they name (a compose file's
    /// env_file) that isn't among them.
    static func parse(
        _ files: [(name: String, text: String)], root: String, more: (String) -> String? = { _ in nil }
    ) -> [FoundDatabase] {
        // Compose fills in ${VAR} from the .env beside the compose file.
        var envs: [String: [String: String]] = [:]
        for (name, text) in files where (name as NSString).lastPathComponent == ".env" {
            envs[(name as NSString).deletingLastPathComponent] = variables(text)
        }
        return files.flatMap { name, text -> [FoundDatabase] in
            let file = (name as NSString).lastPathComponent
            if composeFiles.contains(file) {
                return compose(text, source: name, env: envs[(name as NSString).deletingLastPathComponent] ?? [:]) {
                    path in files.first { $0.name == path }?.text ?? more(path)
                }
            }
            if name == "config/database.yml" { return rails(text, source: name, root: root) }
            if name == "prisma/schema.prisma" { return prisma(text, source: name, root: root) }
            guard file == ".env" || file.hasPrefix(".env."), !file.hasSuffix(".example"), !file.hasSuffix(".sample")
            else { return [] }
            return env(text, source: name, root: root)
        }
    }

    /// The shell line that prints those files on a remote project's host, each after a record separator and its name,
    /// for `parse(remote:)` to read back. SQLite files there aren't looked for, because they can't be opened from here.
    /// It runs in `sh` whatever the host's login shell is, because zsh would stop at the first pattern that matches
    /// nothing.
    static func remoteScript(_ path: String) -> String {
        let names =
            (composeFiles + [".env", ".env.*", "config/database.yml", "prisma/schema.prisma"]
            + (composeFiles + [".env"]).map { "*/" + $0 })
            .joined(separator: " ")
        let script =
            "for f in \(names); do [ -f \"$f\" ] && printf '\\036%s\\n' \"$f\" && head -c 1048576 \"$f\"; done; true"
        return "cd \(RemoteHost.cdArg(path)) 2>/dev/null && exec sh -c " + ShellQuote.word(script)
    }

    static func parse(remote output: String, root: String) -> [FoundDatabase] {
        let files = output.split(separator: "\u{1e}").compactMap { part -> (name: String, text: String)? in
            let lines = part.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard lines.count == 2 else { return nil }
            return (String(lines[0]), String(lines[1]))
        }
        return unique(parse(files, root: root))
    }

    /// Whether a changed file can change what `find` says.
    static func matters(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return composeFiles.contains(name) || name.hasSuffix(".env") || name.hasPrefix(".env.")
            || name == "database.yml"
            || name.hasPrefix("dataSources") || name == "settings.json"
            || sqliteExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func read(_ root: String, _ name: String) -> String? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path), data.count < 1 << 20 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: URLs

    /// Reads a database URL such as postgres://user:pass@host:5432/db, mysql://…, sqlite:///path or file:./dev.db.
    /// Returns nil for anything else.
    static func url(_ text: String, name: String? = nil, source: String, root: String) -> FoundDatabase? {
        let text = DatabaseAddress.withoutDriver(text.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("file:") || text.hasPrefix("sqlite:") {
            var path = text.replacingOccurrences(of: "sqlite://", with: "").replacingOccurrences(
                of: "sqlite:", with: "")
            path = path.replacingOccurrences(of: "file:", with: "")
            path = String(path.split(separator: "?").first ?? "")
            guard !path.isEmpty else { return nil }
            let full = path.hasPrefix("/") ? path : URL(fileURLWithPath: root).appendingPathComponent(path).path
            let base = ((full as NSString).lastPathComponent as NSString).deletingPathExtension
            return FoundDatabase(
                database: DatabaseInfo(
                    name: name ?? base, engine: .sqlite, source: source,
                    path: URL(fileURLWithPath: full).standardized.path))
        }
        // A server's URL is read the way Add Database reads a pasted one, with the same schemes, ssl and all.
        guard text.contains("://") else { return nil }
        let found: DatabaseAddress
        do { found = try DatabaseAddress.parse(text) } catch { return nil }
        guard !found.database.engine.isFile else { return nil }
        var db = found.database
        db.name = name ?? db.name
        db.source = source
        return FoundDatabase(database: db, password: found.password)
    }

    // MARK: .env

    /// Reads lines such as `DATABASE_URL=…` or `export PG_URL="…"`, where the key ends in URL and names a database,
    /// and the value is a database URL, and a database given in separate variables (`separate`).
    static func env(_ text: String, source: String, root: String) -> [FoundDatabase] {
        let urls = pairs(text).compactMap { key, value -> FoundDatabase? in
            let key = key.uppercased()
            guard key.hasSuffix("URL"),
                ["DATABASE", "DB", "POSTGRES", "PG", "MYSQL", "SQLITE"].contains(where: key.contains)
            else { return nil }
            return url(value, source: source, root: root)
        }
        return urls + separate(variables(text), source: source, root: root)
    }

    /// Reads a database given in separate variables: Laravel's and Django's DB_HOST, DB_PORT, DB_DATABASE (or DB_NAME),
    /// DB_USERNAME (or DB_USER) and DB_PASSWORD, with DB_CONNECTION (or DB_ENGINE) or the port saying the engine, and
    /// libpq's PGHOST, PGPORT, PGDATABASE, PGUSER and PGPASSWORD.
    static func separate(_ vars: [String: String], source: String, root: String) -> [FoundDatabase] {
        func value(_ keys: [String]) -> String? { keys.lazy.compactMap { vars[$0] }.first { !$0.isEmpty } }
        func server(_ engine: DatabaseInfo.Engine, _ keys: [[String]]) -> [FoundDatabase] {
            let host = value(keys[0]), database = value(keys[2])
            guard let name = database ?? host else { return [] }
            let db = DatabaseInfo(
                name: name, engine: engine, source: source, host: host ?? "localhost",
                port: value(keys[1]).flatMap(Int.init) ?? engine.defaultPort, database: database, user: value(keys[3]))
            return [FoundDatabase(database: db, password: value(keys[4]))]
        }
        let pg = server(.postgres, [["PGHOST"], ["PGPORT"], ["PGDATABASE"], ["PGUSER"], ["PGPASSWORD"]])
        let laravel = [
            ["DB_HOST"], ["DB_PORT"], ["DB_DATABASE", "DB_NAME"], ["DB_USERNAME", "DB_USER"], ["DB_PASSWORD"]
        ]
        let kind = value(["DB_CONNECTION", "DB_ENGINE"])?.lowercased() ?? "", port = value(["DB_PORT"])
        if kind.contains("sqlite") {
            return pg + (value(laravel[2]).flatMap { url("file:" + $0, source: source, root: root) }.map { [$0] } ?? [])
        }
        if kind.contains("pgsql") || kind.contains("postgres") || kind.isEmpty && port == "5432" {
            return pg + server(.postgres, laravel)
        }
        if kind.contains("mysql") || kind.contains("mariadb") || kind.isEmpty && port == "3306" {
            return pg + server(.mysql, laravel)
        }
        return pg
    }

    static func unquoted(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if let hash = value.range(of: " #"), !value.hasPrefix("\""), !value.hasPrefix("'") {
            value = String(value[..<hash.lowerBound])
        }
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: Rails

    /// Reads the development and test blocks of config/database.yml.
    static func rails(_ text: String, source: String, root: String) -> [FoundDatabase] {
        var blocks: [String: [String: String]] = [:], current: String?
        for raw in expandingAnchors(text).split(whereSeparator: \.isNewline) {
            let line = String(raw), trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" "), trimmed.hasSuffix(":") {
                current = String(trimmed.dropLast())
                continue
            }
            guard let current, let colon = trimmed.firstIndex(of: ":") else { continue }
            let value = unquoted(String(trimmed[trimmed.index(after: colon)...]))
            if !value.contains("<%") { blocks[current, default: [:]][String(trimmed[..<colon])] = value }
        }
        return ["development", "test"].compactMap { env -> FoundDatabase? in
            guard let block = blocks[env], let adapter = block["adapter"], let name = block["database"] else {
                return nil
            }
            if adapter.hasPrefix("sqlite") {
                return url("file:" + name, source: source, root: root)
            }
            let engine: DatabaseInfo.Engine =
                adapter.hasPrefix("postgres") ? .postgres : adapter.hasPrefix("mysql") ? .mysql : .sqlite
            guard engine != .sqlite else { return nil }
            let db = DatabaseInfo(
                name: name, engine: engine, source: source, host: block["host"] ?? "localhost",
                port: block["port"].flatMap(Int.init) ?? engine.defaultPort, database: name,
                user: block["username"])
            return FoundDatabase(database: db, password: block["password"])
        }
    }

    // MARK: Prisma

    /// Reads the datasource's url when the schema writes it out, as `url = "postgresql://…"` or a SQLite
    /// `file:./dev.db` (relative to the schema's folder, as Prisma reads it). For `env("DATABASE_URL")` the value
    /// comes from the .env found there.
    static func prisma(_ text: String, source: String, root: String) -> [FoundDatabase] {
        var inSource = false
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("datasource ") { inSource = true }
            if inSource, line.hasPrefix("}") { inSource = false }
            guard inSource, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), value.dropFirst().contains("\"") else { continue }
            let url = String(value.dropFirst().prefix { $0 != "\"" })
            let folder = (root as NSString).appendingPathComponent((source as NSString).deletingLastPathComponent)
            return self.url(url, source: source, root: folder).map { [$0] } ?? []
        }
        return []
    }

    // MARK: SQLite files

    static let skipped: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "target", "Pods", "vendor", "venv", ".venv", ".kelp",
        "DerivedData"
    ]

    /// Finds SQLite and DuckDB files at the top and in the usual folders. A file with a database extension counts only
    /// when its first bytes say so, because the name alone isn't enough.
    static func sqliteFiles(in root: String) -> [FoundDatabase] {
        var found: [FoundDatabase] = []
        for folder in [""] + sqliteFolders {
            let dir = folder.isEmpty ? root : (root as NSString).appendingPathComponent(folder)
            for name in FileManager.default.names(in: dir).sorted() {
                guard sqliteExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                let path = (dir as NSString).appendingPathComponent(name)
                guard let engine = fileEngine(path) else { continue }
                let source = folder.isEmpty ? name : folder + "/" + name
                found.append(
                    FoundDatabase(
                        database: DatabaseInfo(
                            name: (name as NSString).deletingPathExtension, engine: engine, source: source, path: path)
                    ))
            }
        }
        return found
    }

    /// Tells what a file is by its first bytes: SQLite's header, or DuckDB's ("DUCK" at byte 8).
    static func fileEngine(_ path: String) -> DatabaseInfo.Engine? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let head: Data
        do { head = try handle.read(upToCount: 16) ?? Data() } catch { return nil }
        if head == Data("SQLite format 3\0".utf8) { return .sqlite }
        if head.count >= 12, head[8..<12] == Data("DUCK".utf8) { return .duckdb }
        return nil
    }

    // MARK: Names

    /// Whether the database is a server other than this Mac. Agents only read such a server until the user says
    /// otherwise. Production is only ever the user's word (Environment), never guessed from a host, a name or an
    /// `.env.production`.
    static func isRemote(_ db: DatabaseInfo) -> Bool {
        guard !db.engine.isFile else { return false }
        return db.ssh != nil || db.host.map { !DatabaseInfo.isLocal($0) } ?? false
    }

    /// Keeps one entry per place. The same server, port and database found twice (compose and .env) is kept once, as
    /// first found. Two places under one name get "-2", "-3". A compose service that publishes no port is a place of
    /// its own, whatever its database is called.
    static func unique(_ found: [FoundDatabase]) -> [FoundDatabase] {
        var kept: [FoundDatabase] = [], names: Set<String> = []
        func place(_ item: FoundDatabase) -> String {
            let service = item.service.map { "\u{1F}" + (item.database.source ?? "") + "\u{1F}" + $0.name }
            return item.database.place + (item.database.host == nil ? service ?? "" : "")
        }
        for var item in found {
            let db = item.database
            if kept.contains(where: { place($0) == place(item) }) { continue }
            var name = db.name, n = 2
            while names.contains(name) {
                name = "\(db.name)-\(n)"
                n += 1
            }
            item.database.name = name
            if isRemote(item.database) { item.database.access = .read }
            names.insert(name)
            kept.append(item)
        }
        return kept
    }
}
