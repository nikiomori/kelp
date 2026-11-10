import Core
import Foundation

/// A database found in a project's files, with the password those files give it (never sent to a client).
struct FoundDatabase: Equatable {
    var database: DatabaseInfo
    var password: String?
    /// The compose service it runs in, and its port there: its client can run inside that service's container.
    var service: (name: String, port: Int)?
    /// The folder its source is in when that isn't the workspace's: the project's own, for a branch's workspace.
    var root: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.database == rhs.database && lhs.password == rhs.password && lhs.service?.name == rhs.service?.name
            && lhs.service?.port == rhs.service?.port
    }
}

/// Where a project says its databases are: `.env` files (`DATABASE_URL` and the like), compose services of postgres or
/// mysql images, Rails' config/database.yml, and SQLite files near the top. Only reads files; never connects.
/// Limit: YAML is read line by line (the shapes these files take), not parsed; values from ERB or anchors aren't
/// followed.
enum DatabaseFind {
    static let composeFiles = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
    static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "duckdb", "ddb"]
    /// Folders SQLite files are looked for in, beside the project's own top.
    static let sqliteFolders = ["db", "data", "prisma", "instance", "storage", "var"]

    /// Every database the files at `root` name, each name once.
    static func find(in root: String) -> [FoundDatabase] {
        let envs = names(in: root).filter { $0 == ".env" || $0.hasPrefix(".env.") }.sorted()
        // A monorepo's parts (api/, backend/): their compose files and .env, one level down.
        let parts = names(in: root).filter { !$0.hasPrefix(".") && !skipped.contains($0) }.sorted().flatMap { dir in
            (composeFiles + [".env"]).map { dir + "/" + $0 }
        }
        let files = (composeFiles + envs + ["config/database.yml", "prisma/schema.prisma"] + parts).compactMap { name in
            read(root, name).map { (name, $0) }
        }
        return unique(parse(files, root: root) + ideConnections(in: root) + sqliteFiles(in: root))
    }

    /// What an IDE keeps in the project: JetBrains' .idea/dataSources.xml (the user from the .local.xml beside it),
    /// VS Code's SQLTools in .vscode/settings.json. JetBrains keeps no password there: ~/.pgpass or the user gives one.
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

    /// `sqltools.connections` of a VS Code settings file (JSON with comments and trailing commas).
    static func sqlTools(_ text: String) -> [FoundDatabase] {
        guard text.contains("sqltools.connections") else { return [] }
        let plain = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            .replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        let settings = ImportReaders.optional { try JSONSerialization.jsonObject(with: Data(plain.utf8)) }
        let list = (settings as? [String: Any])?["sqltools.connections"] as? [[String: Any]] ?? []
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

    /// What files of the project say, by their path in it: compose files, .env files, config/database.yml.
    static func parse(_ files: [(name: String, text: String)], root: String) -> [FoundDatabase] {
        // What compose fills ${VAR} in from: the .env beside the compose file.
        var envs: [String: [String: String]] = [:]
        for (name, text) in files where (name as NSString).lastPathComponent == ".env" {
            envs[(name as NSString).deletingLastPathComponent] = variables(text)
        }
        return files.flatMap { name, text -> [FoundDatabase] in
            let file = (name as NSString).lastPathComponent
            if composeFiles.contains(file) {
                return compose(text, source: name, env: envs[(name as NSString).deletingLastPathComponent] ?? [:])
            }
            if name == "config/database.yml" { return rails(text, source: name, root: root) }
            if name == "prisma/schema.prisma" { return prisma(text, source: name, root: root) }
            guard file == ".env" || file.hasPrefix(".env."), !file.hasSuffix(".example"), !file.hasSuffix(".sample")
            else { return [] }
            return env(text, source: name, root: root)
        }
    }

    /// The shell line that prints those files on a remote project's host, each after a record separator and its name:
    /// what `parse(remote:)` reads back. SQLite files there aren't looked for (they can't be opened from here).
    /// In `sh`, whatever the host's login shell: zsh would stop at the first pattern that matches nothing.
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
        return composeFiles.contains(name) || name == ".env" || name.hasPrefix(".env.") || name == "database.yml"
            || name.hasPrefix("dataSources") || name == "settings.json"
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
        // A server's URL is read as one pasted into Add Database is: the same schemes, ssl and all.
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
            if let db = url(value, source: source, root: root) { found.append(db) }
        }
        return found
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
                port: block["port"].flatMap(Int.init) ?? engine.defaultPort, database: name,
                user: block["username"])
            return FoundDatabase(database: db, password: block["password"])
        }
    }

    // MARK: Prisma

    /// The datasource's url when it's written out: `url = "postgresql://…"`, or a SQLite `file:./dev.db` (from the schema's
    /// folder, as Prisma reads it). `env("DATABASE_URL")` is the .env's, found there.
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

    /// SQLite files at the top and in the usual folders: by their first bytes, not their name.
    static func sqliteFiles(in root: String) -> [FoundDatabase] {
        var found: [FoundDatabase] = []
        for folder in [""] + sqliteFolders {
            let dir = folder.isEmpty ? root : (root as NSString).appendingPathComponent(folder)
            for name in names(in: dir).sorted() {
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

    /// What a folder holds; nothing for one that isn't there (most of `sqliteFolders` aren't).
    static func names(in dir: String) -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: dir) } catch { return [] }
    }

    /// SQLite's header, or DuckDB's ("DUCK" at byte 8): what a file is by its first bytes.
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

    /// A server that isn't this Mac: agents only read it until the user says otherwise. Production is only ever the
    /// user's word (Environment), never guessed from a host, a name or an `.env.production`.
    static func isRemote(_ db: DatabaseInfo) -> Bool {
        guard !db.engine.isFile else { return false }
        return db.ssh != nil || db.host.map { !DatabaseInfo.isLocal($0) } ?? false
    }

    /// One entry per place: the same server, port and database found twice (compose and .env) is kept once, the first;
    /// two places under one name get "-2", "-3".
    static func unique(_ found: [FoundDatabase]) -> [FoundDatabase] {
        var kept: [FoundDatabase] = [], names: Set<String> = []
        for var item in found {
            let db = item.database
            if kept.contains(where: { $0.database.place == db.place }) { continue }
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
