import CommonCrypto
import Core
import Foundation
import Testing

@testable import Daemon

/// A home folder with each app's connections written as that app writes them (field names from their own source).
private func fixtureHome() throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kelp-import-\(UUID().uuidString)")
    func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func plist(_ path: String, _ value: Any) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }
    let tp = "Library/Application Support/com.tinyapp.TablePlus/Data/"
    try plist(
        tp + "Connections.plist",
        [
            [
                "ID": "A1", "ConnectionName": "analytics", "Driver": "PostgreSQL", "DatabaseHost": "10.0.3.4",
                "DatabasePort": "5432", "DatabaseName": "analytics", "DatabaseUser": "ro", "Enviroment": "production",
                "GroupID": "G1", "DatabasePasswordMode": 0
            ],
            [
                "ID": "A2", "ConnectionName": "reports", "Driver": "PostgreSQL", "DatabaseHost": "127.0.0.1",
                "DatabasePort": "5432", "DatabaseName": "reports", "isOverSSH": true, "ServerAddress": "box",
                "ServerUser": "me", "ServerPort": "2222", "Enviroment": "local"
            ],
            ["ID": "A3", "ConnectionName": "cache", "Driver": "Redis", "DatabaseHost": "localhost"],
            [
                "ID": "A4", "ConnectionName": "", "Driver": "PostgreSQL", "DatabaseHost": "pg-prod-ro.example.com",
                "DatabaseName": "gis"
            ]
        ])
    try plist(tp + "ConnectionGroups.plist", [["ID": "G1", "Name": "Work"]])

    let dbeaver = "Library/DBeaverData/workspace6/General/.dbeaver/"
    try write(
        dbeaver + "data-sources.json",
        """
        {"folders": {}, "connection-types": {"prod": {"confirm-execute": true}},
         "connections": {
          "postgres-1": {"provider": "postgresql", "driver": "postgres-jdbc", "name": "shop", "save-password": true,
            "configuration": {"host": "localhost", "port": "5432", "database": "shop", "type": "dev",
              "handlers": {"postgre_ssl": {"enabled": true}}}},
          "duck-1": {"provider": "generic", "driver": "duckdb_jdbc", "name": "events",
            "configuration": {"database": "/tmp/events.duckdb", "type": "dev"}}
         }}
        """)
    let credentials = ##"{"postgres-1": {"#connection": {"user": "app", "password": "s3cret"}}}"##
    let iv = Data(repeating: 7, count: 16)
    try (iv + encrypt(Data(credentials.utf8), key: Data(hex: "babb4a9f774ab853c96c2d653dfe544a"), iv: iv))
        .write(to: home.appendingPathComponent(dbeaver + "credentials-config.json"))

    try write(
        "DataGripProjects/airflow/.idea/dataSources.xml",
        """
        <project version="4"><component name="DataSourceManagerImpl">
          <data-source source="LOCAL" name="airflow@prod" uuid="u-1">
            <driver-ref>postgresql</driver-ref><jdbc-url>jdbc:postgresql://db.example.com:5432/airflow</jdbc-url>
          </data-source>
          <data-source source="LOCAL" name="bi" uuid="u-2">
            <driver-ref>postgresql</driver-ref><jdbc-url>jdbc:postgresql://bi.example.com:5432/postgres</jdbc-url>
          </data-source>
        </component></project>
        """)
    try write(
        "DataGripProjects/airflow/.idea/dataSources.local.xml",
        """
        <project version="4"><component name="dataSourceStorageLocal">
          <data-source name="airflow@prod" uuid="u-1"><user-name>airflow</user-name>
            <schema-mapping><introspection-scope><node negative="1">
              <node kind="database"><name qname="@" /><name qname="audit" /></node>
            </node></introspection-scope></schema-mapping>
          </data-source>
          <data-source name="bi" uuid="u-2"><schema-mapping><introspection-scope>
            <node kind="database" qname="reports"><node kind="schema" negative="1" /></node>
          </introspection-scope></schema-mapping></data-source>
        </component></project>
        """)
    try write(".pgpass", "# mine\nlocalhost:5432:app_dev:app:pw1\n*:*:*:*:any\n")
    try write(".pg_service.conf", "[billing]\nhost=billing.internal\ndbname=billing\nuser=ops\nsslmode=require\n")
    try write(".my.cnf", "[client]\nuser = root\npassword = \"rootpw\"\nport = 3307\n")
    try write(
        ".dbgate/connections.jsonl",
        #"{"_id":"g1","engine":"mysql@dbgate-plugin-mysql","server":"localhost","port":"3306","displayName":"legacy"}"#)
    return home
}

private func encrypt(_ data: Data, key: Data, iv: Data) -> Data {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let capacity = out.count
    _ = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { d in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { v in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count, o.baseAddress, capacity,
                        &moved)
                }
            }
        }
    }
    return out.prefix(moved)
}

/// Each app's connections come in as Kelp keeps them: engines it doesn't speak left out, the user's production tag made
/// Production (a host elsewhere isn't), an SSH tunnel kept with what Kelp can't say about it, groups as groups.
@Test func eachAppsConnectionsReadAsKelpKeepsThem() throws {
    let home = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let tp = ImportReaders.read("tableplus", home: home, file: nil).map(\.imported)
    #expect(tp.map(\.database.name) == ["analytics", "reports", "gis@pg-prod-ro"])   // Redis isn't Kelp's
    #expect(tp[0].database.production && tp[0].database.group == "Work" && tp[0].database.user == "ro")
    #expect(tp[1].database.ssh == "me@box" && tp[1].note?.contains("port 2222") == true)
    #expect(!tp[1].database.production && tp[1].database.environment == nil)   // "local" is TablePlus' default: says nothing

    let dbeaver = ImportReaders.read("dbeaver", home: home, file: nil)
    #expect(dbeaver.map(\.imported.database.name) == ["events", "shop"])
    #expect(dbeaver[0].imported.database.engine == .duckdb && dbeaver[0].imported.database.path == "/tmp/events.duckdb")
    #expect(dbeaver[1].imported.database.ssl == "require" && dbeaver[1].imported.database.stage == .local)
    let read = try #require(dbeaver[1].secret)
    let secret = try read()   // its file, under DBeaver's shared key
    #expect(secret.user == "app" && secret.password == "s3cret")

    let grip = ImportReaders.read("datagrip", home: home, file: nil).map(\.imported)
    #expect(grip.first?.database.host == "db.example.com" && grip.first?.database.user == "airflow")
    #expect(grip.first?.database.group == "airflow" && grip.first?.database.production == false)
    // The URL's database when DataGrip shows it ("@"); the one other it shows when it doesn't
    #expect(grip.map(\.database.database) == ["airflow", "reports"])

    let pgpass = ImportReaders.read("pgpass", home: home, file: nil)
    #expect(pgpass.count == 1 && pgpass.first?.imported.database.database == "app_dev")
    let pw = try pgpass.first?.secret?()
    #expect(pw?.password == "pw1")
    let service = ImportReaders.read("pgservice", home: home, file: nil).first?.imported.database
    #expect(service?.name == "billing" && service?.ssl == "require" && service?.production == false)
    let my = ImportReaders.read("mycnf", home: home, file: nil)
    let root = try my.first?.secret?()
    #expect(my.first?.imported.database.port == 3307 && root?.password == "rootpw")
    #expect(ImportReaders.read("dbgate", home: home, file: nil).first?.imported.database.engine == .mysql)
}

/// Through the daemon: the sources found with their counts, what Kelp has already marked, an import into All my
/// projects with passwords from the app's file, used in the project at once.
@Test func anImportLandsInAllMyProjects() async throws {
    let home = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let dbs = w.d.workspaces.databases
    _ = try await w.c.call(DatabaseImportSources())   // this test's own home: whatever it holds
    let sources = dbs.importSources(home: home)
    #expect(sources.first { $0.id == "dbeaver" }?.count == 2 && sources.first { $0.id == "tableplus" }?.count == 3)
    #expect(sources.contains { $0.id == "navicat" } && !sources.contains { $0.id == "sequelace" })

    let outcome = try dbs.importNow(
        DatabaseImport(worktreeId: wt.id, source: "dbeaver", ids: ["postgres-1"], passwords: true, useHere: true),
        home: home)
    #expect(outcome.imported.map(\.name) == ["shop"] && outcome.imported.first?.user == "app")
    #expect(outcome.withPasswords == 1 && outcome.later == 0 && outcome.skipped.isEmpty)
    #expect(try dbs.library().map(\.name) == ["shop"])
    #expect(try dbs.connection(wt.id, "shop", agent: true).password == "s3cret")   // used here: agents see it
    let again = try dbs.importRead(DatabaseImportRead(worktreeId: wt.id, source: "dbeaver"), home: home)
    #expect(again.first { $0.id == "postgres-1" }?.known == true && again.first { $0.id == "duck-1" }?.known == false)
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "shop", library: true))
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "shop"))

    // From TablePlus without taking passwords now: nothing asked, each keeps where its password is for when it's
    // opened; a connection with no name of its own is called by its database and host, and nothing is left out.
    let later = try dbs.importNow(
        DatabaseImport(worktreeId: wt.id, source: "tableplus", ids: ["A1", "A2"], passwords: false, useHere: false),
        home: home)
    #expect(later.imported.count == 2 && later.later == 2 && later.withPasswords == 0)
    #expect(later.imported.first?.passwordIn == "com.tableplus.TablePlus\u{1F}A1_database")
    let dots = try await w.c.call(DatabaseStatus(worktreeId: wt.id, library: true))
    #expect(dots.allSatisfy { $0.state == .unknown })   // not tried: reading the password would make macOS ask
    for db in later.imported { _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: db.name, library: true)) }
}

/// One an older Kelp imported without its password is offered again, and importing it mends it in place: same name,
/// now reading its password from where it came from.
@Test func aConnectionKeptWithoutItsPasswordIsMendedByImportingAgain() async throws {
    let home = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let dbs = w.d.workspaces.databases
    let broken = DatabaseInfo(
        name: "analytics (old)", engine: .postgres, host: "10.0.3.4", port: 5432, database: "analytics", user: "ro")
    _ = try dbs.saveInLibrary(wt.id, broken, password: nil)
    let offered = try dbs.importRead(DatabaseImportRead(worktreeId: wt.id, source: "tableplus"), home: home)
    #expect(offered.first { $0.id == "A1" }?.known == false)
    let mended = try dbs.importNow(
        DatabaseImport(worktreeId: wt.id, source: "tableplus", ids: ["A1"], passwords: false, useHere: false),
        home: home)
    #expect(mended.imported.map(\.name) == ["analytics (old)"] && mended.later == 1)
    #expect(try dbs.library().count == 1 && dbs.library().first?.passwordIn != nil)
    let again = try dbs.importRead(DatabaseImportRead(worktreeId: wt.id, source: "tableplus"), home: home)
    #expect(again.first { $0.id == "A1" }?.known == true)
    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "analytics (old)", library: true))
}

/// A host the network doesn't know, said as such.
@Test func aHostNobodyKnowsIsSaidSo() async {
    let db = DatabaseInfo(name: "x", engine: .postgres, host: "kelp-no-such-host.invalid", port: 5432)
    await #expect(
        throws: DatabaseFailure.failed(
            "Can't find kelp-no-such-host.invalid on the network: is a VPN or SSH needed to reach it?")
    ) {
        try await PostgresWire.read(DatabaseConnection(database: db), "SELECT 1", timeout: 3)
    }
}
