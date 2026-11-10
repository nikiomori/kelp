import Core
import Foundation

/// Import Connections: what the apps on this Mac keep (`ImportReaders`), read into All my projects as a copy. Passwords
/// only when the user asked, each keychain item asked of macOS; one "Don't Allow" and the rest come without theirs.
extension Databases {
    func importSources(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [ImportSource] {
        let found = ImportReaders.apps.compactMap { app -> ImportSource? in
            let entries = ImportReaders.read(app.id, home: home, file: nil)
            guard !entries.isEmpty else { return nil }
            let engines = DatabaseInfo.Engine.allCases.filter { engine in
                entries.contains { $0.imported.database.engine == engine }
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
        // Known: Kelp has it with its password (or where to read it). One kept without is offered again, to mend.
        let mine = try library().filter(hasPassword) + connections(q.worktreeId).map(\.database)
        return ImportReaders.read(q.source, home: home, file: q.file).map { entry in
            var item = entry.imported
            item.known = mine.contains { Self.sameAddress($0, item.database) }
            return item
        }
    }

    func importNow(_ q: DatabaseImport, home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> ImportOutcome {
        let wanted = Set(q.ids)
        let had = try library()
        var taken = Set(had.map(\.name)), denied = false
        var outcome = ImportOutcome(imported: [], withPasswords: 0, later: 0, denied: false, skipped: [])
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
            // Not taken now from another app's keychain: read the first time it's opened, macOS asking then.
            if password == nil, let item = entry.keychain { db.passwordIn = item }
            // One imported before (an older Kelp kept it without its password): mended in place, under its name.
            if let old = had.first(where: { Self.sameAddress($0, db) }) {
                db.name = old.name
                db.access = old.access
                db.environment = old.environment
                db.production = old.production
                taken.remove(old.name)
            } else {
                db.access = DatabaseInfo.Access(rawValue: sessions.settings[SettingKeys.databaseAccess]) ?? .ask
            }
            let base = db.name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
            var name = base.isEmpty ? "imported" : base, n = 2
            while taken.contains(name) {
                name = "\(base)-\(n)"
                n += 1
            }
            db.name = name
            do {
                outcome.imported.append(try saveInLibrary(q.worktreeId, db, password: password))   // nil keeps one kept
                taken.insert(name)
                if password != nil { outcome.withPasswords += 1 } else if db.passwordIn != nil { outcome.later += 1 }
                if q.useHere {
                    _ = try use(q.worktreeId, name, access: db.production || DatabaseFind.isRemote(db) ? .read : nil)
                }
            } catch let error as RPCError {
                outcome.skipped.append("\(entry.imported.database.name): \(error.message)")
            }
        }
        outcome.denied = denied
        return outcome
    }

    /// Its password is in Kelp's keychain, or Kelp knows which app's to read it from.
    func hasPassword(_ db: DatabaseInfo) -> Bool {
        db.engine.isFile || db.passwordIn != nil || Keychain.get(Self.libraryAccount(db.name)) != nil
    }

    /// The same server and database, or the same file.
    static func sameAddress(_ a: DatabaseInfo, _ b: DatabaseInfo) -> Bool {
        // DBeaver keeps its user with the password: one without a user can be either
        a.place == b.place && (a.engine.isFile || a.user == nil || b.user == nil || a.user == b.user)
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
    func handle(_ dbs: Databases) async throws -> ImportOutcome {
        try await dbs.offloads.run { try dbs.importNow(self) }
    }
}

extension ImportReaders {
    static func text(_ url: URL) -> String? {
        do { return try String(contentsOf: url, encoding: .utf8) } catch { return nil }
    }
}
