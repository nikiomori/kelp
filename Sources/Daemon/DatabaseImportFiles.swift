import Core
import Foundation

/// Connections kept in the standards' plain files (~/.pgpass, ~/.pg_service.conf, ~/.my.cnf) and in exports the user
/// picks (pgAdmin's servers.json, Navicat's .ncx).
enum ImportFiles {
    /// One connection a line that names a host; the password is in the line.
    static func pgpass(_ home: URL) -> [ImportEntry] {
        guard let text = ImportReaders.text(home.appendingPathComponent(".pgpass")) else { return [] }
        return text.split(whereSeparator: \.isNewline).enumerated().compactMap { index, line in
            guard !line.hasPrefix("#") else { return nil }
            let f = PgPass.fields(String(line))
            guard f.count == 5, f[0] != "*" else { return nil }
            let database = f[2] == "*" ? nil : f[2], user = f[3] == "*" ? nil : f[3]
            var db = DatabaseInfo(
                name: database ?? f[0], engine: .postgres, host: f[0], port: Int(f[1]) ?? 5432, database: database,
                user: user)
            let note = ImportReaders.production(&db, tag: nil, app: "~/.pgpass")
            let password = f[4]
            return ImportEntry(
                imported: ImportedDatabase(id: "\(index)", database: db, note: note),
                secret: { ImportSecret(password: password) })
        }
    }

    /// `[name]` then libpq's words, a line each.
    static func pgService(_ home: URL) -> [ImportEntry] {
        let path =
            ProcessInfo.processInfo.environment["PGSERVICEFILE"] ?? home.appendingPathComponent(".pg_service.conf").path
        guard let text = ImportReaders.text(URL(fileURLWithPath: path)) else { return [] }
        return ini(text).compactMap { name, v in
            guard let host = v["host"] ?? v["hostaddr"] else { return nil }
            var db = DatabaseInfo(
                name: name, engine: .postgres, host: host, port: v["port"].flatMap { Int($0) } ?? 5432,
                database: v["dbname"], user: v["user"])
            db.ssl = DatabaseAddress.ssl(v["sslmode"])
            let note = ImportReaders.production(&db, tag: nil, app: "pg_service.conf")
            let password = v["password"]
            return ImportEntry(
                imported: ImportedDatabase(id: name, database: db, note: note),
                secret: { ImportSecret(password: password) })
        }
    }

    /// MySQL's client settings: `[client]` (or `[mysql]`) is one connection.
    static func myCnf(_ home: URL) -> [ImportEntry] {
        guard let text = ImportReaders.text(home.appendingPathComponent(".my.cnf")) else { return [] }
        let sections = Dictionary(ini(text), uniquingKeysWith: { a, _ in a })
        let v = (sections["client"] ?? [:]).merging(sections["mysql"] ?? [:]) { _, b in b }
        guard !v.isEmpty else { return [] }
        let host = v["host"] ?? "localhost"
        var db = DatabaseInfo(
            name: v["database"] ?? "my.cnf", engine: .mysql, host: host, port: v["port"].flatMap { Int($0) } ?? 3306,
            database: v["database"], user: v["user"])
        let note = ImportReaders.production(&db, tag: nil, app: "~/.my.cnf")
        let password = v["password"]
        return [
            ImportEntry(
                imported: ImportedDatabase(id: "client", database: db, note: note),
                secret: { ImportSecret(password: password) })
        ]
    }

    /// pgAdmin's File › Export Servers: no passwords in it.
    static func pgAdmin(_ url: URL) -> [ImportEntry] {
        guard let servers = ImportReaders.jsonObject(url)?["Servers"] as? [String: [String: Any]] else { return [] }
        return servers.sorted { $0.key < $1.key }.compactMap { id, s in
            guard let host = ImportReaders.nonEmpty(s["Host"]) else { return nil }
            var db = DatabaseInfo(
                name: ImportReaders.string(s["Name"]), engine: .postgres, host: host,
                port: ImportReaders.int(s["Port"]) ?? 5432, database: ImportReaders.nonEmpty(s["MaintenanceDB"]),
                user: ImportReaders.nonEmpty(s["Username"]))
            db.group = ImportReaders.nonEmpty(s["Group"])
            let params = s["ConnectionParameters"] as? [String: Any] ?? [:]
            db.ssl = DatabaseAddress.ssl(ImportReaders.nonEmpty(params["sslmode"] ?? s["SSLMode"]))
            var note: String?
            if ImportReaders.int(s["UseSSHTunnel"]) == 1 {
                (db.ssh, note) = ImportReaders.ssh(
                    host: ImportReaders.string(s["TunnelHost"]), user: ImportReaders.nonEmpty(s["TunnelUsername"]),
                    port: ImportReaders.int(s["TunnelPort"]), key: ImportReaders.int(s["TunnelAuthentication"]) == 1)
            }
            note = ImportReaders.both(note, ImportReaders.production(&db, tag: nil, app: "pgAdmin"))
            return ImportEntry(imported: ImportedDatabase(id: id, database: db, note: note), secret: nil)
        }
    }

    /// Navicat's File › Export Connections: XML; a saved password is AES-128-CBC under Navicat's own key and IV.
    static func navicat(_ url: URL) -> [ImportEntry] {
        let nodes: [XMLNode]
        do { nodes = try XMLDocument(contentsOf: url).nodes(forXPath: "//Connection") } catch { return [] }
        return nodes.enumerated().compactMap { index, node in
            guard let c = node as? XMLElement else { return nil }
            func a(_ name: String) -> String? { ImportReaders.nonEmpty(c.attribute(forName: name)?.stringValue) }
            guard let engine = ImportReaders.engine(a("ConnType") ?? "") else { return nil }
            let name = a("ConnectionName") ?? "navicat"
            var db =
                engine.isFile
                ? DatabaseInfo(name: name, engine: engine, path: a("DatabaseFileName"))
                : DatabaseInfo(
                    name: name, engine: engine, host: a("Host"), port: a("Port").flatMap { Int($0) },
                    database: a("Database"), user: a("UserName"))
            var note: String?
            if a("SSH") == "true" {
                (db.ssh, note) = ImportReaders.ssh(
                    host: a("SSH_Host") ?? "", user: a("SSH_UserName"), port: a("SSH_Port").flatMap { Int($0) },
                    key: a("SSH_AuthenMethod") == "PUBLICKEY")
            }
            note = ImportReaders.both(note, ImportReaders.production(&db, tag: nil, app: "Navicat"))
            let hex = a("Password")
            return ImportEntry(
                imported: ImportedDatabase(id: "\(index)", database: db, note: note),
                secret: hex.map { hex in
                    { @Sendable in
                        let plain = ImportReaders.aes128CBC(
                            Data(hex: hex), key: Data("libcckeylibcckey".utf8), iv: Data("libcciv libcciv ".utf8))
                        return ImportSecret(password: plain.flatMap { String(data: $0, encoding: .utf8) })
                    }
                })
        }
    }

    /// `[section]` then `key = value` lines; `#` and `;` start comments.
    static func ini(_ text: String) -> [(String, [String: String])] {
        var out: [(String, [String: String])] = [], name: String?, values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                if let name { out.append((name, values)) }
                name = String(line.dropFirst().dropLast())
                values = [:]
            } else if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                values[key] = DatabaseAddress.unquoted(
                    line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            }
        }
        if let name { out.append((name, values)) }
        return out
    }
}
