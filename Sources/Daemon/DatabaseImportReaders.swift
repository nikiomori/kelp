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
        let host = nonEmpty(c["DatabaseHost"]).map { h in
            h.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
                ? h : String(h.split(separator: ".").first ?? Substring(h))
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
            let p = tunnel["properties"] as? [String: Any] ?? [:]
            (db.ssh, note) = ssh(
                host: string(p["host"]), user: nonEmpty(p["user"]), port: int(p["port"]),
                key: string(p["authType"]) == "PUBLIC_KEY")
        }
        if let ssl = handlers["postgre_ssl"] ?? handlers["mysql_ssl"], ssl["enabled"] as? Bool == true {
            db.ssl = "require"
        }
        let type = string(cfg["type"])
        let prod = type == "prod" || (types[type]?["confirm-execute"] as? Bool == true && type != "dev")
        note = ImportReaders.both(note, production(&db, tag: prod ? "production" : type, app: "DBeaver"))
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
                name: name, engine: .mysql, host: host, port: int(node["port"]) ?? 3306,
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
        return rows.compactMap { r in
            guard let engine = engine(string(r["connectionType"])) else { return nil }
            let name: String = r["name"] ?? "beekeeper"
            var db =
                engine.isFile
                ? DatabaseInfo(name: name, engine: engine, path: r["defaultDatabase"])
                : DatabaseInfo(
                    name: name, engine: engine, host: r["host"], port: r["port"], database: r["defaultDatabase"],
                    user: r["username"])
            var note: String?
            if (r["sshEnabled"] as Bool?) == true {
                (db.ssh, note) = ssh(host: r["sshHost"] ?? "", user: r["sshUsername"], port: r["sshPort"], key: false)
            }
            note = ImportReaders.both(
                note, production(&db, tag: (r["labelColor"] as String?) == "red" ? "production" : nil, app: "Beekeeper")
            )
            return ImportEntry(imported: ImportedDatabase(id: string(r["id"]), database: db, note: note), secret: nil)
        }
    }

    static func dbGate(_ home: URL) -> [ImportEntry] {
        guard let lines = text(home.appendingPathComponent(".dbgate/connections.jsonl")) else { return [] }
        return lines.split(whereSeparator: \.isNewline).compactMap { line in
            guard let c = optional({ try JSONSerialization.jsonObject(with: Data(line.utf8)) }) as? [String: Any],
                let engine = engine(string(c["engine"]).split(separator: "@").first.map(String.init) ?? "")
            else { return nil }
            let name = nonEmpty(c["displayName"]) ?? nonEmpty(c["server"]) ?? nonEmpty(c["databaseFile"]) ?? "dbgate"
            var db =
                engine.isFile
                ? DatabaseInfo(name: name, engine: engine, path: nonEmpty(c["databaseFile"]))
                : DatabaseInfo(
                    name: name, engine: engine, host: nonEmpty(c["server"]), port: int(c["port"]),
                    database: nonEmpty(c["defaultDatabase"]), user: nonEmpty(c["user"]))
            db.group = nonEmpty(c["parent"])
            var note: String?
            if c["useSshTunnel"] as? Bool == true {
                (db.ssh, note) = ssh(
                    host: string(c["sshHost"]), user: nonEmpty(c["sshLogin"]), port: int(c["sshPort"]),
                    key: string(c["sshMode"]) == "keyFile")
            }
            note = ImportReaders.both(
                note, production(&db, tag: c["isReadOnly"] as? Bool == true ? "production" : nil, app: "DbGate"))
            return ImportEntry(imported: ImportedDatabase(id: string(c["_id"]), database: db, note: note), secret: nil)
        }
    }

    // MARK: Pieces

    /// An app's driver name as Kelp's engine; nil for one Kelp doesn't speak.
    static func engine(_ driver: String) -> DatabaseInfo.Engine? {
        let d = driver.lowercased()
        if ["postgres", "cockroach", "redshift", "greenplum", "timescale", "supabase", "neon"].contains(
            where: d.contains)
        {
            return .postgres
        }
        if d.contains("mysql") || d.contains("maria") || d.contains("tidb") || d.contains("planetscale") {
            return .mysql
        }
        if d.contains("duckdb") { return .duckdb }
        if d.contains("sqlite") || d.contains("libsql") { return .sqlite }
        return nil
    }

    /// An SSH tunnel as Kelp keeps one: `user@host`, ssh's own config doing the rest; what it can't say, said.
    static func ssh(host: String, user: String?, port: Int?, key: Bool) -> (String?, String?) {
        guard !host.isEmpty else { return (nil, nil) }
        let alias = user.map { $0 + "@" + host } ?? host
        if let port, port != 22 {
            return (alias, "SSH on port \(port): give \(host) a Port line in ~/.ssh/config.")
        }
        return (alias, key ? "An SSH key of its own: give \(host) an IdentityFile in ~/.ssh/config." : nil)
    }

    /// Production when the app says so, or when it isn't on this Mac and the app doesn't call it a test or staging
    /// one. TablePlus' "local" and DBeaver's "dev" are what a new connection gets there: they say nothing.
    @discardableResult
    static func production(_ db: inout DatabaseInfo, tag: String?, app: String) -> String? {
        let tag = tag?.lowercased() ?? ""
        if ["production", "prod"].contains(tag) {
            db.production = true
            return "Production in \(app): agents only read it."
        }
        let remote = db.ssh != nil || db.host.map { !isThisMac($0) } ?? false
        if remote, !["development", "testing", "test", "staging"].contains(tag) {
            db.production = true
            return "Not on this Mac: Production until you say otherwise."
        }
        return nil
    }

    /// Stricter than a project's files (where a bare "db" is a compose service): an app's "db-prod" is a host elsewhere.
    static func isThisMac(_ host: String) -> Bool {
        let host = host.lowercased()
        return ["localhost", "::1", "0.0.0.0", "host.docker.internal"].contains(host) || host.hasPrefix("127.")
            || host.hasSuffix(".localhost")
    }

    /// A keychain item as `DatabaseInfo.passwordIn` keeps it.
    static func keychainItem(_ service: String, _ account: String?) -> String {
        service + "\u{1F}" + (account ?? "")
    }

    /// `passwordIn`'s item, read: macOS asks the user. Nil when it isn't there.
    static func borrowed(_ item: String) throws -> String? {
        let parts = item.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return try otherKeychain(service: parts[0], account: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    /// Another app's keychain item: macOS asks the user whether Kelp may read it. Nil when there's none.
    static func otherKeychain(service: String, account: String?) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        if [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed].contains(status) {
            throw KeychainDenied()
        }
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func aes128CBC(_ data: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count, o.baseAddress, capacity,
                            &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    static func plist(_ url: URL) -> Any? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return optional { try PropertyListSerialization.propertyList(from: data, format: nil) }
    }

    static func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return optional { try JSONSerialization.jsonObject(with: data) } as? [String: Any]
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: ""
        }
    }

    static func nonEmpty(_ value: Any?) -> String? {
        let s = string(value).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func int(_ value: Any?) -> Int? { Int(string(value)) }

    /// Two notes in one line: what SSH needs, then why it's Production.
    static func both(_ a: String?, _ b: String?) -> String? {
        let parts = [a, b].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Another app's file that may be missing, cut short, or of a version Kelp doesn't know: nothing to bring in.
    static func optional<T>(_ body: () throws -> T?) -> T? {
        do { return try body() } catch { return nil }
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
