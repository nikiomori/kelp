import Foundation

/// What's pasted into Add Database, read as a database: a URL (postgres://, mysql://, jdbc:…, sqlite:, duckdb:),
/// libpq's `host=… dbname=…` words, a `psql` or `mysql` command line, an .env line (`DATABASE_URL=…`), or a file's
/// path. The password comes apart from the rest: it goes to the keychain, never into what's shown.
public struct DatabaseAddress: Equatable, Sendable {
    public var database: DatabaseInfo
    public var password: String?

    public init(database: DatabaseInfo, password: String? = nil) {
        self.database = database
        self.password = password
    }

    /// Why the text isn't a database, said so the user can fix it.
    public struct Problem: Error, Equatable {
        public var message: String
        public init(message: String) { self.message = message }
    }

    public static func parse(_ pasted: String) throws(Problem) -> DatabaseAddress {
        var text = unquoted(pasted.trimmingCharacters(in: .whitespacesAndNewlines))
        if let value = envValue(text) { text = unquoted(value) }
        guard !text.isEmpty else { throw Problem(message: "Paste an address, or drop a database file.") }
        if text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("./") { return file(text) }
        let words = shellWords(text)
        if let program = words.first, ["psql", "mysql", "mariadb"].contains((program as NSString).lastPathComponent) {
            return try command(words)
        }
        if text.contains("://") || text.hasPrefix("jdbc:") || text.hasPrefix("sqlite:") || text.hasPrefix("file:")
            || text.hasPrefix("duckdb:")
        {
            return try url(text)
        }
        if text.range(of: #"(^|\s)(host|dbname|hostaddr)\s*="#, options: .regularExpression) != nil {
            return try keywords(text)
        }
        throw Problem(message: "That isn't a database address: paste one such as postgres://user@host:5432/db.")
    }

    // MARK: Forms

    static func file(_ path: String) -> DatabaseAddress {
        let full = (path as NSString).expandingTildeInPath
        let ext = (full as NSString).pathExtension.lowercased()
        let base = ((full as NSString).lastPathComponent as NSString).deletingPathExtension
        return DatabaseAddress(
            database: DatabaseInfo(name: base, engine: ["duckdb", "ddb"].contains(ext) ? .duckdb : .sqlite, path: full))
    }

    static func url(_ text: String) throws(Problem) -> DatabaseAddress {
        var text = text
        if text.hasPrefix("jdbc:") { text.removeFirst(5) }
        let scheme = String(text.prefix { $0 != ":" }).lowercased()
        if ["sqlite", "sqlite3", "file", "duckdb"].contains(scheme) {
            var path = String(text.dropFirst(scheme.count + 1))
            while path.hasPrefix("//") { path.removeFirst() }
            path = String(path.split(separator: "?").first ?? "")
            guard !path.isEmpty else { throw Problem(message: "The address names no file.") }
            var found = file(path)
            if scheme == "duckdb" { found.database.engine = .duckdb }
            return found
        }
        let engine: DatabaseInfo.Engine
        switch scheme {
        case "postgres", "postgresql", "pg", "postgis", "timescale", "cockroachdb": engine = .postgres
        case "mysql", "mysql2", "mariadb", "mysqlx": engine = .mysql
        default:
            throw Problem(
                message: "Kelp doesn't speak \(scheme):// yet: Postgres, MySQL, SQLite and DuckDB.")
        }
        guard let parts = URLComponents(string: text) else { throw Problem(message: "The address can't be read.") }
        let host = parts.host.flatMap { $0.isEmpty ? nil : $0 } ?? "localhost"   // postgres:///app: libpq's default
        let query = Dictionary(
            (parts.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let database = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding
        let user = (parts.user ?? query["user"])?.removingPercentEncoding
        var db = DatabaseInfo(
            name: database.flatMap { $0.isEmpty ? nil : $0 } ?? host, engine: engine, host: host,
            port: parts.port ?? engine.defaultPort,
            database: database?.isEmpty == false ? database : nil,
            user: user)
        db.ssl = ssl(query["sslmode"] ?? query["ssl-mode"] ?? query["ssl"])
        return DatabaseAddress(database: db, password: (parts.password ?? query["password"])?.removingPercentEncoding)
    }

    /// libpq's: `host=db port=5432 dbname=app user=app password='it''s'`.
    static func keywords(_ text: String) throws(Problem) -> DatabaseAddress {
        var values: [String: String] = [:]
        for match in text.matches(of: #/(\w+)\s*=\s*('(?:[^'\\]|\\.)*'|\S*)/#) {
            var value = String(match.2)
            if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\'", with: "'")
            }
            values[match.1.lowercased()] = value
        }
        guard let host = values["host"] ?? values["hostaddr"] else {
            throw Problem(message: "The words name no host: add host=….")
        }
        var db = DatabaseInfo(
            name: values["dbname"] ?? host, engine: .postgres, host: host,
            port: values["port"].flatMap { Int($0) } ?? DatabaseInfo.Engine.postgres.defaultPort,
            database: values["dbname"], user: values["user"])
        db.ssl = ssl(values["sslmode"])
        return DatabaseAddress(database: db, password: values["password"])
    }

    /// `psql -h db -p 5432 -U app app_dev`, `psql postgres://…`, `mysql -h db -P 3306 -u app -psecret shop`.
    static func command(_ words: [String]) throws(Problem) -> DatabaseAddress {
        let mysql = (words[0] as NSString).lastPathComponent != "psql"
        if let address = words.dropFirst().first(where: { $0.contains("://") || $0.contains("=") && !$0.hasPrefix("-") }
        ) {
            return address.contains("://") ? try url(address) : try keywords(address)
        }
        var flags: [String: String] = [:], positional: [String] = []
        var index = 1
        while index < words.count {
            let arg = words[index]
            index += 1
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                flags[String(arg[arg.index(arg.startIndex, offsetBy: 2)..<eq])] = String(arg[arg.index(after: eq)...])
            } else if mysql, arg.hasPrefix("-p") {
                flags["password"] = String(arg.dropFirst(2))   // -psecret: attached, or none (asked for)
            } else if arg.hasPrefix("-"), arg.count == 2 {
                if index < words.count { flags[String(arg.dropFirst())] = words[index] }
                index += 1
            } else if arg.hasPrefix("-"), arg.count > 2, !arg.hasPrefix("--") {
                flags[String(arg.dropFirst().prefix(1))] = String(arg.dropFirst(2))   // -hdb
            } else if !arg.hasPrefix("-") {
                positional.append(arg)
            }
        }
        let host = flags["h"] ?? flags["host"] ?? "localhost"
        let engine: DatabaseInfo.Engine = mysql ? .mysql : .postgres
        let port = (flags[mysql ? "P" : "p"] ?? flags["port"]).flatMap { Int($0) } ?? engine.defaultPort
        let user =
            flags[mysql ? "u" : "U"] ?? flags["user"] ?? flags["username"]
            ?? (mysql ? nil : positional.dropFirst().first)
        let database = flags[mysql ? "D" : "d"] ?? flags["database"] ?? flags["dbname"] ?? positional.first
        let db = DatabaseInfo(
            name: database ?? host, engine: engine, host: host, port: port, database: database,
            user: user)
        let password = flags["password"].flatMap { $0.isEmpty ? nil : $0 }
        return DatabaseAddress(database: db, password: password)
    }

    // MARK: Pieces

    /// libpq's sslmode as Kelp keeps it: "disable", "require" (verify-* too: the server must offer TLS), or nil.
    public static func ssl(_ mode: String?) -> String? {
        switch mode?.lowercased() {
        case "disable", "disabled", "false", "0": "disable"
        case "require", "required", "verify-ca", "verify-full", "verify_identity", "true", "1": "require"
        default: nil
        }
    }

    /// `DATABASE_URL=…` or `export DATABASE_URL="…"`: the value.
    static func envValue(_ text: String) -> String? {
        guard let match = text.firstMatch(of: #/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/#) else {
            return nil
        }
        // libpq's words (host=db dbname=app) look alike: one of their names isn't a variable
        let libpq = ["host", "hostaddr", "dbname", "user", "port", "password", "sslmode"]
        return libpq.contains(match.1.lowercased()) ? nil : String(match.2)
    }

    public static func unquoted(_ text: String) -> String {
        for quote in ["\"", "'", "`"] where text.count >= 2 && text.hasPrefix(quote) && text.hasSuffix(quote) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// A command line split as a shell would: quotes group, backslash escapes.
    static func shellWords(_ text: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for c in text {
            if escaped {
                word.append(c)
                escaped = false
            } else if c == "\\" && quote != "'" {
                escaped = true
            } else if let open = quote {
                if c == open { quote = nil } else { word.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                started = true
            } else if c.isWhitespace {
                if started || !word.isEmpty { words.append(word) }
                word = ""
                started = false
            } else {
                word.append(c)
            }
        }
        if started || !word.isEmpty { words.append(word) }
        return words
    }
}
