import Core
import Foundation

/// Import Connections: what the apps on this Mac keep (`ImportReaders`), read into All my projects as a copy. Passwords
/// only when the user asked, each keychain item asked of macOS; one "Don't Allow" and the rest come without theirs.
extension Databases {
    func importSources(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [ImportSource] {
        let found = ImportReaders.apps.compactMap { app -> ImportSource? in
            let entries = ImportReaders.read(app.id, home: home, file: nil)
            guard !entries.isEmpty else { return nil }
            let engines = DatabaseInfo.Engine.allCases.filter { e in
                entries.contains { $0.imported.database.engine == e }
            }
            return ImportSource(
                id: app.id, name: app.name, count: entries.count, engines: engines, passwords: app.passwords)
        }
        return found
            + ImportReaders.files.map {
                ImportSource(id: $0.id, name: $0.name, count: 0, engines: [], passwords: $0.passwords)
            }
    }

    func importRead(_ q: DatabaseImportRead, home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws
        -> [ImportedDatabase]
    {
        let known = try library() + connections(q.worktreeId).map(\.database)
        return ImportReaders.read(q.source, home: home, file: q.file).map { entry in
            var item = entry.imported
            item.known = known.contains { Self.sameAddress($0, item.database) }
            return item
        }
    }

    func importNow(_ q: DatabaseImport, home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> [DatabaseInfo] {
        let wanted = Set(q.ids)
        var taken = Set(try library().map(\.name)), denied = false, made: [DatabaseInfo] = []
        for entry in ImportReaders.read(q.source, home: home, file: q.file) where wanted.contains(entry.imported.id) {
            var db = entry.imported.database
            var password: String?
            if q.passwords, !denied, let secret = entry.secret {
                do {
                    let got = try secret()
                    password = got.password
                    db.user = db.user ?? got.user
                } catch is KeychainDenied {
                    denied = true
                } catch {
                    Log.store.info("db import: \(db.name)'s password: \(error)")
                }
            }
            var name = db.name.replacingOccurrences(of: "/", with: "-"), n = 2
            while taken.contains(name) {
                name = "\(db.name)-\(n)"
                n += 1
            }
            db.name = name
            taken.insert(name)
            db.access = DatabaseInfo.Access(rawValue: sessions.settings[SettingKeys.databaseAccess]) ?? .ask
            made.append(try saveInLibrary(q.worktreeId, db, password: password ?? ""))
            if q.useHere {
                _ = try use(q.worktreeId, name, access: db.production || db.ssh != nil ? .read : nil)
            }
        }
        return made
    }

    /// The same server and database, or the same file.
    static func sameAddress(_ a: DatabaseInfo, _ b: DatabaseInfo) -> Bool {
        guard a.engine == b.engine else { return false }
        if a.engine.isFile { return a.path == b.path }
        let local = { (h: String?) in h.map { DatabaseFind.isLocal($0) ? "localhost" : $0.lowercased() } ?? "" }
        let sameUser = a.user == nil || b.user == nil || a.user == b.user   // DBeaver keeps its user with the password
        return local(a.host) == local(b.host) && a.port == b.port && a.database == b.database && sameUser
            && a.ssh == b.ssh
    }
}

extension DatabaseImportSources: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> [ImportSource] { try await dbs.offloads.run { dbs.importSources() } }
}

extension DatabaseImportRead: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> [ImportedDatabase] {
        try await dbs.offloads.run { try dbs.importRead(self) }
    }
}

extension DatabaseImport: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> [DatabaseInfo] {
        try await dbs.offloads.run { try dbs.importNow(self) }
    }
}

extension ImportReaders {
    static func text(_ url: URL) -> String? {
        do { return try String(contentsOf: url, encoding: .utf8) } catch { return nil }
    }
}
