import CommonCrypto
import Core
import Foundation
import GRDB
import Security

/// A connection read from another app, and how to get its user and password, called only when the user asked for
/// passwords: it may make macOS ask (keychain), or decrypt the app's file.
struct ImportEntry: Sendable {
    var imported: ImportedDatabase
    var secret: (@Sendable () throws -> ImportSecret)?
    /// Its password's keychain item, when that's where it is: read on first use instead of at import.
    var keychain: String?
}

struct ImportSecret: Sendable {
    var user: String?, password: String?
}

/// The user said no to macOS's question for another app's keychain item: Kelp asks no more this import.
struct KeychainDenied: Error {}

/// Other apps' saved connections, each read from where that app keeps them (their formats were read from their own
/// source, and TablePro's importers). `home` is the user's home folder; tests hand one of their own.
enum ImportReaders {
    static let apps: [(id: String, name: String, passwords: String)] = [
        ("tableplus", "TablePlus", "keychain"), ("dbeaver", "DBeaver", "file"), ("datagrip", "DataGrip", "keychain"),
        ("sequelace", "Sequel Ace", "keychain"), ("beekeeper", "Beekeeper Studio", "none"),
        ("dbgate", "DbGate", "none"),
        ("pgpass", "~/.pgpass", "file"), ("pgservice", "~/.pg_service.conf", "file"), ("mycnf", "~/.my.cnf", "file")
    ]
    /// Read from an export the user picks.
    static let files: [(id: String, name: String, passwords: String)] = [
        ("pgadmin", "pgAdmin servers.json", "none"), ("navicat", "Navicat .ncx", "file")
    ]

    static func read(_ source: String, home: URL, file: String?) -> [ImportEntry] {
        switch source {
        case "tableplus": tablePlus(home)
        case "dbeaver": dbeaver(home)
        case "datagrip": dataGrip(home)
        case "sequelace": sequelAce(home)
        case "beekeeper": beekeeper(home)
        case "dbgate": dbGate(home)
        case "pgpass": ImportFiles.pgpass(home)
        case "pgservice": ImportFiles.pgService(home)
        case "mycnf": ImportFiles.myCnf(home)
        case "pgadmin": file.map { ImportFiles.pgAdmin(URL(fileURLWithPath: $0)) } ?? []
        case "navicat": file.map { ImportFiles.navicat(URL(fileURLWithPath: $0)) } ?? []
        default: []
        }
    }

    // MARK: TablePlus

    static func tablePlus(_ home: URL) -> [ImportEntry] {
        let support = home.appendingPathComponent("Library/Application Support")
        let dir = ["com.tinyapp.TablePlus", "com.tinyapp.TablePlus-setapp"].map {
            support.appendingPathComponent($0 + "/Data")
        }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Connections.plist").path) }
        guard let dir, let list = plist(dir.appendingPathComponent("Connections.plist")) as? [[String: Any]] else {
            return []
        }
        let groups = (plist(dir.appendingPathComponent("ConnectionGroups.plist")) as? [[String: Any]] ?? [])
            .reduce(into: [String: String]()) { $0[string($1["ID"])] = $1["Name"] as? String }
        return list.compactMap { tablePlusEntry($0, groups: groups) }
    }

    private static func tablePlusEntry(_ c: [String: Any], groups: [String: String]) -> ImportEntry? {
        let id = string(c["ID"])
        guard let engine = engine(string(c["Driver"])) else { return nil }
        // A connection TablePlus shows by its address has no name of its own: "database@host", as it reads there.
        // its host's first word ("pg-prod-ro"); an address in numbers whole
        let host = nonEmpty(c["DatabaseHost"]).map { written in
            written.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
                ? written : String(written.split(separator: ".").first ?? Substring(written))
        }
        let address = [nonEmpty(c["DatabaseName"]), host].compactMap { $0 }.joined(separator: "@")
        let name =
            nonEmpty(c["ConnectionName"]) ?? (address.isEmpty ? nil : address)
            ?? nonEmpty(c["DatabasePath"]).map { ($0 as NSString).lastPathComponent } ?? "tableplus"
        var db = DatabaseInfo(
            name: name, engine: engine, host: nonEmpty(c["DatabaseHost"]),
            port: int(c["DatabasePort"]), database: nonEmpty(c["DatabaseName"]), user: nonEmpty(c["DatabaseUser"]),
            path: nonEmpty(c["DatabasePath"]))
        db.group = groups[string(c["GroupID"])]
        var note: String?
        if c["isOverSSH"] as? Bool == true {
            (db.ssh, note) = ssh(
                host: string(c["ServerAddress"]), user: nonEmpty(c["ServerUser"]), port: int(c["ServerPort"]),
                key: c["isUsePrivateKey"] as? Bool == true)
        }
        note = ImportReaders.both(note, production(&db, tag: nonEmpty(c["Enviroment"]), app: "TablePlus"))
        let secret: (@Sendable () throws -> ImportSecret)? =
            (c["DatabasePasswordMode"] as? Int ?? 0) == 0
            ? { @Sendable in
                ImportSecret(password: try otherKeychain(service: "com.tableplus.TablePlus", account: id + "_database"))
            }
            : nil
        return ImportEntry(
            imported: ImportedDatabase(id: id, database: db, note: note), secret: secret,
            keychain: secret == nil ? nil : keychainItem("com.tableplus.TablePlus", id + "_database"))
    }

    // MARK: DBeaver

    static func dbeaver(_ home: URL) -> [ImportEntry] {
        let workspace = home.appendingPathComponent("Library/DBeaverData/workspace6")
        var entries: [ImportEntry] = []
        for project in DatabaseFind.names(in: workspace.path).sorted() where !project.hasPrefix(".") {
            let dir = workspace.appendingPathComponent(project + "/.dbeaver")
            for file in DatabaseFind.names(in: dir.path).sorted()
            where file.hasPrefix("data-sources") && file.hasSuffix(".json") {
                let credentials = dir.appendingPathComponent(
                    file.replacingOccurrences(of: "data-sources", with: "credentials-config"))
                entries += dbeaverFile(dir.appendingPathComponent(file), credentials: credentials)
            }
        }
        return entries
    }

    static func dbeaverFile(_ url: URL, credentials: URL) -> [ImportEntry] {
        guard let json = jsonObject(url), let connections = json["connections"] as? [String: [String: Any]] else {
            return []
        }
        let types = json["connection-types"] as? [String: [String: Any]] ?? [:]
        return connections.sorted { $0.key < $1.key }.compactMap {
            dbeaverEntry($0.key, $0.value, types: types, credentials: credentials)
        }
    }

    private static func dbeaverEntry(
        _ id: String, _ c: [String: Any], types: [String: [String: Any]], credentials: URL
    ) -> ImportEntry? {
        let cfg = c["configuration"] as? [String: Any] ?? [:]
        let provider = string(c["provider"]), driver = string(c["driver"])
        guard let engine = engine(provider == "generic" ? driver : provider) ?? engine(driver) else { return nil }
        guard var db = dbeaverAddress(c, cfg, engine) else { return nil }
        db.group = nonEmpty(c["folder"])
        var note: String?
        let handlers = cfg["handlers"] as? [String: [String: Any]] ?? [:]
        if let tunnel = handlers["ssh_tunnel"], tunnel["enabled"] as? Bool == true {
            let properties = tunnel["properties"] as? [String: Any] ?? [:]
            (db.ssh, note) = ssh(
                host: string(properties["host"]), user: nonEmpty(properties["user"]), port: int(properties["port"]),
                key: string(properties["authType"]) == "PUBLIC_KEY")
        }
        if let ssl = handlers["postgre_ssl"] ?? handlers["mysql_ssl"], ssl["enabled"] as? Bool == true {
            db.ssl = "require"
        }
        let type = string(cfg["type"])
        let prod = type == "prod" || (types[type]?["confirm-execute"] as? Bool == true && type != "dev")
        note = ImportReaders.both(
            note, production(&db, tag: prod ? "production" : type == "dev" ? nil : type, app: "DBeaver"))
        let secret: (@Sendable () throws -> ImportSecret)? =
            c["save-password"] as? Bool == false
            ? nil
            : { @Sendable in
                let mine = (try dbeaverCredentials(credentials)[id] as? [String: Any])?["#connection"] as? [String: Any]
                return ImportSecret(user: nonEmpty(mine?["user"]), password: nonEmpty(mine?["password"]))
            }
        return ImportEntry(imported: ImportedDatabase(id: id, database: db, note: note), secret: secret)
    }

    /// A file's path, a host's address, or the JDBC URL it was given as.
    private static func dbeaverAddress(_ c: [String: Any], _ cfg: [String: Any], _ engine: DatabaseInfo.Engine)
        -> DatabaseInfo?
    {
        let name = string(c["name"])
        if engine.isFile {
            let url = nonEmpty(cfg["url"]).map {
                $0.replacingOccurrences(of: #"^jdbc:\w+:"#, with: "", options: .regularExpression)
            }
            guard let raw = nonEmpty(cfg["database"]) ?? url else { return nil }
            return DatabaseInfo(name: name, engine: engine, path: (raw as NSString).expandingTildeInPath)
        }
        if let host = nonEmpty(cfg["host"]) {
            return DatabaseInfo(
                name: name, engine: engine, host: host, port: int(cfg["port"]), database: nonEmpty(cfg["database"]),
                user: nonEmpty(cfg["user"]))
        }
        guard let url = nonEmpty(cfg["url"]) else { return nil }
        do {
            var db = try DatabaseAddress.parse(url).database
            db.name = name
            return db
        } catch { return nil }
    }

    /// DBeaver's credentials-config.json: AES-128-CBC under a key every DBeaver install shares, the IV first.
    static func dbeaverCredentials(_ url: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path), data.count > 16 else { return [:] }
        let key = Data(hex: "babb4a9f774ab853c96c2d653dfe544a")
        guard let plain = aes128CBC(data.dropFirst(16), key: key, iv: data.prefix(16)) else { return [:] }
        return (try JSONSerialization.jsonObject(with: plain)) as? [String: Any] ?? [:]
    }

    // MARK: DataGrip and JetBrains IDEs

    static func dataGrip(_ home: URL) -> [ImportEntry] {
        let jetbrains = home.appendingPathComponent("Library/Application Support/JetBrains")
        var files: [(xml: URL, group: String?)] = []
        var projects = Set<String>()
        for product in DatabaseFind.names(in: jetbrains.path).sorted() {
            let options = jetbrains.appendingPathComponent(product + "/options")
            files.append((options.appendingPathComponent("dataSources.xml"), nil))
            if let recent = text(options.appendingPathComponent("recentProjects.xml")) {
                for match in recent.matches(of: #/<entry key="([^"]+)"/#) {
                    projects.insert(String(match.1).replacingOccurrences(of: "$USER_HOME$", with: home.path))
                }
            }
        }
        let gripProjects = home.appendingPathComponent("DataGripProjects")
        for name in DatabaseFind.names(in: gripProjects.path) {
            projects.insert(gripProjects.appendingPathComponent(name).path)
        }
        for project in projects.sorted() {
            files.append(
                (
                    URL(fileURLWithPath: project).appendingPathComponent(".idea/dataSources.xml"),
                    (project as NSString).lastPathComponent
                ))
        }
        return files.flatMap { dataSources($0.xml, group: $0.group) }
    }

    /// One dataSources.xml and the .local.xml beside it (the user name, SSH).
    static func dataSources(_ url: URL, group: String?) -> [ImportEntry] {
        guard let sources = optional({ try XMLDocument(contentsOf: url).nodes(forXPath: "//data-source") }) else {
            return []
        }
        let local = optional {
            try XMLDocument(contentsOf: url.deletingLastPathComponent().appendingPathComponent("dataSources.local.xml"))
        }
        return sources.compactMap { node -> ImportEntry? in
            guard let element = node as? XMLElement, let uuid = element.attribute(forName: "uuid")?.stringValue,
                let name = element.attribute(forName: "name")?.stringValue,
                let url = element.elements(forName: "jdbc-url").first?.stringValue,
                var db = optional({ try DatabaseAddress.parse(url).database })
            else { return nil }
            db.name = name
            db.group = element.attribute(forName: "group-name")?.stringValue ?? group
            let mine = optional { try local?.nodes(forXPath: "//data-source[@uuid='\(uuid)']") }?.first as? XMLElement
            db.user = mine?.elements(forName: "user-name").first?.stringValue ?? db.user
            // A URL to one database (often "postgres") whose tables DataGrip shows from one other: that one
            // ("@" is the URL's). Only the database nodes' own names: a <name> deeper down is a schema's.
            let scope = ".//introspection-scope//node[@kind='database' and not(@negative)]"
            let shown = Set(
                (optional { try mine?.nodes(forXPath: "\(scope)/@qname | \(scope)/name/@qname") } ?? [])
                    .compactMap(\.stringValue))
            if shown.count == 1, let only = shown.first, only != "@" { db.database = only }
            var note: String?
            if let ssh = mine?.elements(forName: "ssh-properties").first,
                ssh.elements(forName: "enabled").first?.stringValue == "true"
            {
                note = "SSH in DataGrip: set it by hand (Edit… › SSH)."
            }
            note = ImportReaders.both(note, production(&db, tag: nil, app: "DataGrip"))
            return ImportEntry(
                imported: ImportedDatabase(id: uuid, database: db, note: note),
                secret: {
                    ImportSecret(password: try otherKeychain(service: "IntelliJ Platform DB — \(uuid)", account: nil))
                }, keychain: keychainItem("IntelliJ Platform DB — \(uuid)", nil))
        }
    }

    // MARK: Sequel Ace

    static func sequelAce(_ home: URL) -> [ImportEntry] {
        let url = home.appendingPathComponent(
            "Library/Containers/com.sequel-ace.sequel-ace/Data/Library/Application Support/Sequel Ace/Data/Favorites.plist"
        )
        guard let root = (plist(url) as? [String: Any])?["Favorites Root"] as? [String: Any] else { return [] }
        var entries: [ImportEntry] = []
        func walk(_ node: [String: Any], group: String?) {
            if let children = node["Children"] as? [[String: Any]] {
                for child in children { walk(child, group: node["Name"] as? String ?? group) }
                return
            }
            let id = string(node["id"]), name = string(node["name"])
            guard !name.isEmpty, let host = nonEmpty(node["host"]) else { return }
            var db = DatabaseInfo(
                name: name, engine: .mysql, host: host,
                port: int(node["port"]) ?? DatabaseInfo.Engine.mysql.defaultPort,
                database: nonEmpty(node["database"]), user: nonEmpty(node["user"]))
            db.group = group == "Favorites" ? nil : group
            var note: String?
            if int(node["type"]) == 2 {
                (db.ssh, note) = ssh(
                    host: string(node["sshHost"]), user: nonEmpty(node["sshUser"]), port: int(node["sshPort"]),
                    key: node["sshKeyLocationEnabled"] as? Int == 1)
            }
            note = ImportReaders.both(
                note, production(&db, tag: int(node["colorIndex"]) == 0 ? "production" : nil, app: "Sequel Ace"))
            let account = "\(db.user ?? "")@\(host)/\(db.database ?? "")"
            entries.append(
                ImportEntry(
                    imported: ImportedDatabase(id: id, database: db, note: note),
                    secret: {
                        ImportSecret(
                            password: try otherKeychain(service: "Sequel Ace : \(name) (\(id))", account: account))
                    }, keychain: keychainItem("Sequel Ace : \(name) (\(id))", account)))
        }
        walk(root, group: nil)
        return entries
    }

    // MARK: Beekeeper Studio, DbGate (passwords under keys of their own: typed again)

    static func beekeeper(_ home: URL) -> [ImportEntry] {
        let path = home.appendingPathComponent("Library/Application Support/beekeeper-studio/app.db").path
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let rows: [Row]
        do {
            rows = try SQLiteRun.open(path, readOnly: true).read {
                try Row.fetchAll($0, sql: "SELECT * FROM saved_connection")
            }
        } catch {
            return []
        }
        return rows.compactMap { row in
            guard let engine = engine(string(row["connectionType"])) else { return nil }
            let name: String = row["name"] ?? "beekeeper"
            var db =
                engine.isFile
                ? DatabaseInfo(name: name, engine: engine, path: row["defaultDatabase"])
                : DatabaseInfo(
                    name: name, engine: engine, host: row["host"], port: row["port"], database: row["defaultDatabase"],
                    user: row["username"])
            var note: String?
            if (row["sshEnabled"] as Bool?) == true {
                (db.ssh, note) = ssh(
                    host: row["sshHost"] ?? "", user: row["sshUsername"], port: row["sshPort"], key: false)
            }
            note = ImportReaders.both(
                note,
                production(&db, tag: (row["labelColor"] as String?) == "red" ? "production" : nil, app: "Beekeeper")
            )
            return ImportEntry(imported: ImportedDatabase(id: string(row["id"]), database: db, note: note), secret: nil)
        }
    }

    static func dbGate(_ home: URL) -> [ImportEntry] {
        guard let lines = text(home.appendingPathComponent(".dbgate/connections.jsonl")) else { return [] }
        return lines.split(whereSeparator: \.isNewline).compactMap { line in
            guard
                let connection = optional({ try JSONSerialization.jsonObject(with: Data(line.utf8)) })
                    as? [String: Any],
                let engine = engine(string(connection["engine"]).split(separator: "@").first.map(String.init) ?? "")
            else { return nil }
            let name =
                nonEmpty(connection["displayName"]) ?? nonEmpty(connection["server"]) ?? nonEmpty(
                    connection["databaseFile"]) ?? "dbgate"
            var db =
                engine.isFile
                ? DatabaseInfo(name: name, engine: engine, path: nonEmpty(connection["databaseFile"]))
                : DatabaseInfo(
                    name: name, engine: engine, host: nonEmpty(connection["server"]), port: int(connection["port"]),
                    database: nonEmpty(connection["defaultDatabase"]), user: nonEmpty(connection["user"]))
            db.group = nonEmpty(connection["parent"])
            var note: String?
            if connection["useSshTunnel"] as? Bool == true {
                (db.ssh, note) = ssh(
                    host: string(connection["sshHost"]), user: nonEmpty(connection["sshLogin"]),
                    port: int(connection["sshPort"]),
                    key: string(connection["sshMode"]) == "keyFile")
            }
            note = ImportReaders.both(
                note,
                production(&db, tag: connection["isReadOnly"] as? Bool == true ? "production" : nil, app: "DbGate"))
            return ImportEntry(
                imported: ImportedDatabase(id: string(connection["_id"]), database: db, note: note), secret: nil)
        }
    }
}
