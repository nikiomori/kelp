import Core
import Foundation

/// A database found in a project's files, with the password those files give it (never sent to a client).
struct FoundDatabase: Equatable {
    var database: DatabaseInfo
    var password: String?
}

/// Where a project says its databases are: `.env` files (`DATABASE_URL` and the like), compose services of postgres or
/// mysql images, Rails' config/database.yml, and SQLite files near the top. Only reads files; never connects.
/// Limit: YAML is read line by line (the shapes these files take), not parsed; values from ERB or anchors aren't
/// followed.
enum DatabaseFind {
    static let composeFiles = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
    static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db3"]
    /// Folders SQLite files are looked for in, beside the project's own top.
    static let sqliteFolders = ["db", "data", "prisma", "instance", "storage", "var"]

    /// Every database the files at `root` name, each name once.
    static func find(in root: String) -> [FoundDatabase] {
        var found: [FoundDatabase] = []
        for name in composeFiles {
            if let text = read(root, name) { found += compose(text, source: name) }
        }
        let envs = names(in: root).filter { $0 == ".env" || $0.hasPrefix(".env.") }
        for name in envs.sorted() where !name.hasSuffix(".example") && !name.hasSuffix(".sample") {
            if let text = read(root, name) { found += env(text, source: name, root: root) }
        }
        if let text = read(root, "config/database.yml") {
            found += rails(text, source: "config/database.yml", root: root)
        }
        found += sqliteFiles(in: root)
        return unique(found)
    }

    /// Whether a changed file can change what `find` says.
    static func matters(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return composeFiles.contains(name) || name == ".env" || name.hasPrefix(".env.") || name == "database.yml"
            || sqliteExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func read(_ root: String, _ name: String) -> String? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path), data.count < 1 << 20 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: URLs

    /// postgres://user:pass@host:5432/db, mysql://…, sqlite:///path or file:./dev.db; nil for anything else.
    static func url(_ text: String, name: String? = nil, source: String, root: String) -> FoundDatabase? {
        let text = text.trimmingCharacters(in: .whitespaces)
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
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased() else { return nil }
        let engine: DatabaseInfo.Engine
        switch scheme {
        case "postgres", "postgresql": engine = .postgres
        case "mysql", "mysql2", "mariadb": engine = .mysql
        default: return nil
        }
        let database = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let db = DatabaseInfo(
            name: name ?? (database.isEmpty ? engine.rawValue : database), engine: engine, source: source,
            host: parts.host.flatMap { $0.isEmpty ? nil : $0 } ?? "localhost",
            port: parts.port ?? (engine == .postgres ? 5432 : 3306), database: database.isEmpty ? nil : database,
            user: parts.user?.removingPercentEncoding ?? parts.user)
        return FoundDatabase(database: db, password: parts.password?.removingPercentEncoding ?? parts.password)
    }

    // MARK: .env

    /// `DATABASE_URL=…`, `export PG_URL="…"`: a key ending URL that names a database, its value a database URL.
    static func env(_ text: String, source: String, root: String) -> [FoundDatabase] {
        var found: [FoundDatabase] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            guard key.hasSuffix("URL"),
                ["DATABASE", "DB", "POSTGRES", "PG", "MYSQL", "SQLITE"].contains(where: key.contains)
            else { continue }
            let value = unquoted(String(line[line.index(after: eq)...]))
            if var db = url(value, source: source, root: root) {
                db.database.production = isProduction(db.database)
                found.append(db)
            }
        }
        return found
    }

    private static func unquoted(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if let hash = value.range(of: " #"), !value.hasPrefix("\""), !value.hasPrefix("'") {
            value = String(value[..<hash.lowerBound])
        }
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: compose

    /// Services of a postgres or mysql image: their published port, user, password and database from `environment`.
    static func compose(_ text: String, source: String) -> [FoundDatabase] {
        var found: [FoundDatabase] = []
        for service in services(text) {
            guard let image = service.values["image"]?.lowercased() else { continue }
            let engine: DatabaseInfo.Engine
            if ["postgres", "postgis", "timescale", "pgvector"].contains(where: image.contains) {
                engine = .postgres
            } else if image.contains("mysql") || image.contains("mariadb") {
                engine = .mysql
            } else {
                continue
            }
            let env = service.env, inner = engine == .postgres ? 5432 : 3306
            let port = service.ports.compactMap { published($0, inner: inner) }.first
            var user: String?, password: String?, database: String?
            if engine == .postgres {
                user = env["POSTGRES_USER"] ?? "postgres"
                password = env["POSTGRES_PASSWORD"]
                database = env["POSTGRES_DB"] ?? user
            } else {
                user = env["MYSQL_USER"] ?? env["MARIADB_USER"] ?? "root"
                password =
                    user == "root"
                    ? env["MYSQL_ROOT_PASSWORD"] ?? env["MARIADB_ROOT_PASSWORD"]
                    : env["MYSQL_PASSWORD"] ?? env["MARIADB_PASSWORD"]
                database = env["MYSQL_DATABASE"] ?? env["MARIADB_DATABASE"]
            }
            let db = DatabaseInfo(
                name: database ?? service.name, engine: engine, source: source, host: port == nil ? nil : "localhost",
                port: port, database: database, user: user)
            found.append(FoundDatabase(database: db, password: password))
        }
        return found
    }

    struct Service {
        var name: String
        var values: [String: String] = [:]
        var ports: [String] = []
        var env: [String: String] = [:]
    }

    /// The `services:` block, line by line: a service at the first indent under it, its keys under that.
    static func services(_ text: String) -> [Service] {
        var services: [Service] = [], inServices = false, serviceIndent = -1, section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inServices = trimmed == "services:"
                serviceIndent = -1
                continue
            }
            guard inServices else { continue }
            if serviceIndent < 0 { serviceIndent = indent }
            if indent == serviceIndent {
                services.append(Service(name: String(trimmed.dropLast(trimmed.hasSuffix(":") ? 1 : 0))))
                section = ""
                continue
            }
            guard indent > serviceIndent, !services.isEmpty else { continue }
            let last = services.count - 1
            if trimmed.hasPrefix("- ") {
                let item = unquoted(String(trimmed.dropFirst(2)))
                if section == "ports" { services[last].ports.append(item) }
                if section == "environment", let eq = item.firstIndex(of: "=") {
                    services[last].env[String(item[..<eq])] = unquoted(String(item[item.index(after: eq)...]))
                }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]), value = unquoted(String(trimmed[trimmed.index(after: colon)...]))
            if indent == serviceIndent + 2 || section.isEmpty {
                section = value.isEmpty ? key : ""
                if !value.isEmpty { services[last].values[key] = value }
            } else if section == "environment" {
                services[last].env[key] = value
            }
        }
        return services
    }

    /// The port on this Mac a `ports:` entry publishes `inner` on: "5433:5432", "127.0.0.1:5433:5432", "5432".
    static func published(_ entry: String, inner: Int) -> Int? {
        let parts = entry.split(separator: "/").first.map { $0.split(separator: ":").map(String.init) } ?? []
        guard let target = parts.last.flatMap(Int.init), target == inner else { return nil }
        return parts.count >= 2 ? Int(parts[parts.count - 2]) : nil
    }

    // MARK: Rails

    /// config/database.yml's development and test blocks.
    static func rails(_ text: String, source: String, root: String) -> [FoundDatabase] {
        var blocks: [String: [String: String]] = [:], current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
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
                port: block["port"].flatMap(Int.init) ?? (engine == .postgres ? 5432 : 3306), database: name,
                user: block["username"])
            return FoundDatabase(database: db, password: block["password"])
        }
    }

    // MARK: SQLite files

    static let skipped: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "target", "Pods", "vendor", "venv", ".venv", ".kelp",
        "DerivedData"
    ]

    /// SQLite files at the top and in the usual folders: by their first bytes, not their name.
    static func sqliteFiles(in root: String) -> [FoundDatabase] {
        var found: [FoundDatabase] = []
        for folder in [""] + sqliteFolders {
            let dir = folder.isEmpty ? root : (root as NSString).appendingPathComponent(folder)
            for name in names(in: dir).sorted() {
                guard sqliteExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                let path = (dir as NSString).appendingPathComponent(name)
                guard isSQLite(path) else { continue }
                let source = folder.isEmpty ? name : folder + "/" + name
                found.append(
                    FoundDatabase(
                        database: DatabaseInfo(
                            name: (name as NSString).deletingPathExtension, engine: .sqlite, source: source, path: path)
                    ))
            }
        }
        return found
    }

    /// What a folder holds; nothing for one that isn't there (most of `sqliteFolders` aren't).
    static func names(in dir: String) -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: dir) } catch { return [] }
    }

    static func isSQLite(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        do { return try handle.read(upToCount: 16) == Data("SQLite format 3\0".utf8) } catch { return false }
    }

    // MARK: Names

    /// Not on this Mac, or named for production.
    static func isProduction(_ db: DatabaseInfo) -> Bool {
        let named = [db.name, db.source ?? "", db.database ?? ""].contains { $0.lowercased().contains("prod") }
        guard let host = db.host?.lowercased(), db.engine != .sqlite else { return named }
        let local =
            ["localhost", "127.0.0.1", "::1", "0.0.0.0", "host.docker.internal"].contains(host)
            || host.hasSuffix(".local") || host.hasSuffix(".localhost") || !host.contains(".")
        return named || !local
    }

    /// One entry per place: the same server, port and database found twice (compose and .env) is kept once, the first;
    /// two places under one name get "-2", "-3".
    static func unique(_ found: [FoundDatabase]) -> [FoundDatabase] {
        var kept: [FoundDatabase] = [], names: Set<String> = []
        for var item in found {
            let db = item.database
            let same = kept.contains {
                $0.database.engine == db.engine && $0.database.path == db.path && $0.database.port == db.port
                    && $0.database.database == db.database && ($0.database.host ?? "") == (db.host ?? "")
            }
            if same { continue }
            var name = db.name, n = 2
            while names.contains(name) {
                name = "\(db.name)-\(n)"
                n += 1
            }
            item.database.name = name
            if item.database.engine != .sqlite || item.database.production {
                item.database.production = isProduction(item.database)
            }
            if item.database.production { item.database.access = .read }
            names.insert(name)
            kept.append(item)
        }
        return kept
    }
}
