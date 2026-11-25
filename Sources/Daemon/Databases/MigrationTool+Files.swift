import Core
import Foundation

// Where each migration tool keeps its migrations in a project, read as the tools themselves name them.
extension MigrationTool {
    /// The migrations in the project's folder, at the tool's usual place.
    func files(in root: String) -> [File] {
        switch self {
        case .rails: Self.named(root + "/db/migrate", ext: "rb", parts: 1, keyIsId: true)
        case .prisma: Self.named(root + "/prisma/migrations", ext: "", parts: 1)   // a folder each
        case .laravel: Self.named(root + "/database/migrations", ext: "php", parts: 4)
        case .django: Self.django(root)
        case .alembic: ["/alembic/versions", "/migrations/versions"].flatMap { Self.alembic(root + $0) }
        case .drizzle: Self.drizzle(root + "/drizzle/meta/_journal.json")
        }
    }

    /// What a folder holds; none when there's no such folder, as most of the tools' aren't there.
    private static func entries(_ folder: String) -> [String] {
        guard FileManager.default.fileExists(atPath: folder) else { return [] }
        return Log.store.attempt("listing \(folder)") { try FileManager.default.contentsOfDirectory(atPath: folder) }
            ?? []
    }

    /// Files (or, with no `ext`, folders) named "<id>_<name>": Rails' table keeps the id, Prisma's and Laravel's the
    /// whole name.
    private static func named(_ folder: String, ext: String, parts: Int, keyIsId: Bool = false) -> [File] {
        entries(folder).compactMap { entry in
            let stem = (entry as NSString).deletingPathExtension
            guard (entry as NSString).pathExtension == ext, let (id, name) = split(stem, parts: parts) else {
                return nil
            }
            return File(key: keyIsId ? id : stem, id: id, name: name)
        }
    }

    /// Each app's migrations folder, one or two folders down ("shop/migrations", "apps/shop/migrations"). The app is
    /// the folder the migrations are in, as Django names it unless told otherwise.
    private static func django(_ root: String) -> [File] {
        let skipped: Set = ["node_modules", "venv", "env", "site-packages"]
        let top = entries(root).filter { !$0.hasPrefix(".") && !skipped.contains($0) }.map { root + "/" + $0 }
        let apps = top + top.flatMap { dir in entries(dir).filter { !$0.hasPrefix(".") }.map { dir + "/" + $0 } }
        return apps.flatMap { app in
            let label = (app as NSString).lastPathComponent
            return entries(app + "/migrations").compactMap { entry -> File? in
                let stem = (entry as NSString).deletingPathExtension
                guard entry.hasSuffix(".py"), let (id, name) = Self.django(app: label, stem) else { return nil }
                return File(key: label + "/" + stem, id: id, name: name)
            }
        }
    }

    /// Alembic's revisions, each file saying its own revision and the ones it follows (`down_revision`, several for a
    /// merge).
    private static func alembic(_ folder: String) -> [File] {
        entries(folder).filter { $0.hasSuffix(".py") }.compactMap { entry in
            let path = folder + "/" + entry
            guard
                let text = Log.store.attempt("reading \(path)", { try String(contentsOfFile: path, encoding: .utf8) }),
                let revision = text.firstMatch(of: #/(?m)^revision\s*(?::[^=\n]*)?=\s*['"]([^'"]+)['"]/#)?.1
            else { return nil }
            let down = text.firstMatch(of: #/(?m)^down_revision\s*(?::[^=\n]*)?=(.*)$/#)?.1 ?? ""
            let parents = down.matches(of: #/['"]([^'"]+)['"]/#).map { String($0.1) }
            let stem = (entry as NSString).deletingPathExtension
            let name = stem.hasPrefix(revision + "_") ? String(stem.dropFirst(revision.count + 1)) : stem
            return File(key: String(revision), id: String(revision), name: name, parents: parents)
        }
    }

    /// Drizzle's journal, which lists each migration's tag and when it was made.
    private static func drizzle(_ journal: String) -> [File] {
        struct Journal: Decodable {
            struct Entry: Decodable {
                var when: Int64, tag: String
            }
            var entries: [Entry]
        }
        guard let data = FileManager.default.contents(atPath: journal),
            let read = Log.store.attempt("reading \(journal)", { try JSONDecoder().decode(Journal.self, from: data) })
        else { return [] }
        return read.entries.map { entry in
            let (id, name) = split(entry.tag, parts: 1) ?? (entry.tag, "")
            return File(key: entry.tag, id: id, name: name, when: entry.when)
        }
    }
}

extension Databases {
    /// Adds the migrations to a whole schema read: what the tool's table says was applied, against the workspace's
    /// folder. The panel's line takes the count from here. Limit: a remote project's folder is on its host, so there
    /// only the table is read.
    /// A failure leaves them out, as the schema reads without them.
    func withMigrations(_ schema: DatabaseSchema, _ target: DatabaseConnection, _ worktreeId: String) async
        -> DatabaseSchema
    {
        guard let (tool, table) = MigrationTool.of(schema) else { return schema }
        do {
            let sql = tool.applied(table, target.database.engine)
            let rows = try await DatabaseEngines.read(target, sql, off: offloads).rows
            let migrations = try await offloads.run { [self] in
                tool.status(table: table, rows: rows, root: try store.worktree(worktreeId)?.path)
            }
            var schema = schema
            schema.migrations = migrations
            noteMigrations(worktreeId, target.database.name, migrations.notApplied.count)
            return schema
        } catch {
            Log.store.error("reading \(target.database.name)'s migrations: \(error)")
            return schema
        }
    }
}
