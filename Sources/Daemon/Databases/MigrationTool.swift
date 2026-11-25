import Core
import Foundation

/// The migration tools Kelp recognises: the table each keeps in the database, and where its migrations are in the
/// project. They are read once with the schema (`db.schema`), never on a timer, and nothing here changes the database.
enum MigrationTool: CaseIterable {
    case rails, prisma, django, alembic, drizzle, laravel

    /// One migration in the project's folder. `key` is what the tool's table holds for it once applied. Alembic's
    /// `parents` are its down revisions, and Drizzle's `when` is the time its journal gives it.
    struct File: Equatable {
        var key: String, id: String, name: String
        var parents: [String] = [], when: Int64?
    }

    /// The tool's table, and a column only its table has, so an app's own "migrations" table isn't taken for one.
    var table: (name: String, column: String) {
        switch self {
        case .rails: ("schema_migrations", "version")
        case .prisma: ("_prisma_migrations", "migration_name")
        case .django: ("django_migrations", "app")
        case .alembic: ("alembic_version", "version_num")
        case .drizzle: ("__drizzle_migrations", "created_at")
        case .laravel: ("migrations", "migration")
        }
    }

    /// Reads what the table says was applied, one key per row (Django's is its app and name, as "shop/0001_initial").
    /// Limit: a read keeps 1000 rows, so a project with more applied migrations shows the rest as not applied.
    func applied(_ table: String, _ engine: DatabaseInfo.Engine) -> String {
        let from = " FROM " + engine.table(table)
        return switch self {
        case .rails: "SELECT version" + from
        case .prisma: "SELECT migration_name" + from + " WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL"
        case .django: "SELECT app, name" + from
        case .alembic: "SELECT version_num" + from
        case .drizzle: "SELECT created_at" + from
        case .laravel: "SELECT migration" + from
        }
    }

    /// The tool whose table the schema has, and that table's name as the schema lists it ("drizzle.__drizzle_…").
    static func of(_ schema: DatabaseSchema) -> (tool: MigrationTool, table: String)? {
        for tool in allCases {
            let found = schema.tables.first { table in
                table.kind == nil && (table.name.split(separator: ".").last.map(String.init) == tool.table.name)
                    && table.columns.contains { $0.name == tool.table.column }
            }
            if let found { return (tool, found.name) }
        }
        return nil
    }

    /// Puts the table's keys against the folder's migrations, oldest first. A key the folder doesn't have (its file
    /// is gone, or it is a library's, as Django's own apps are) is listed as applied.
    func status(table: String, rows: [[String?]], root: String?) -> DatabaseMigrations {
        let keys = Set(rows.map { $0.compactMap { $0 }.joined(separator: "/") })
        let found = root.map(files) ?? []
        let applied = appliedKeys(keys, found)
        var all = found.map {
            DatabaseMigrations.Migration(id: $0.id, name: $0.name, applied: applied.contains($0.key))
        }
        let known = Set(found.map(\.key))
        all += keys.subtracting(known).compactMap(named).map {
            DatabaseMigrations.Migration(id: $0.id, name: $0.name, applied: true)
        }
        if self == .alembic {   // revisions are random: their order is the chain's
            let depth = Self.depths(found)
            all.sort { (depth[$0.id] ?? 0) < (depth[$1.id] ?? 0) }
        } else {
            all.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
        return DatabaseMigrations(table: table, all: all)
    }

    /// The keys of the folder's migrations that count as applied. Alembic's table holds only the latest revision, so
    /// every revision under it is applied; Drizzle's holds when each ran, so every migration up to the latest is.
    private func appliedKeys(_ keys: Set<String>, _ found: [File]) -> Set<String> {
        switch self {
        case .alembic:
            let parents = Dictionary(found.map { ($0.key, $0.parents) }, uniquingKeysWith: { a, _ in a })
            var applied = Set<String>(), next = Array(keys)
            while let key = next.popLast() {
                if applied.insert(key).inserted { next += parents[key] ?? [] }
            }
            return applied
        case .drizzle:
            guard let last = keys.compactMap({ Int64($0) }).max() else { return [] }
            return Set(found.filter { ($0.when ?? .max) <= last }.map(\.key))
        default: return keys
        }
    }

    /// The id and name of a key only the table has. Nil for Alembic and Drizzle, whose keys are no names.
    private func named(_ key: String) -> (id: String, name: String)? {
        switch self {
        case .rails: (key, "")
        case .prisma: Self.split(key, parts: 1) ?? (key, "")
        case .laravel: Self.split(key, parts: 4) ?? (key, "")
        case .django:
            key.split(separator: "/", maxSplits: 1).count == 2
                ? Self.django(app: String(key.split(separator: "/")[0]), String(key.split(separator: "/")[1])) : nil
        case .alembic, .drizzle: nil
        }
    }

    /// "20261122_add_paid_at" → ("20261122", "add_paid_at"); Laravel's id is its first four parts
    /// ("2026_11_22_000000").
    static func split(_ stem: String, parts: Int) -> (id: String, name: String)? {
        let pieces = stem.split(separator: "_", omittingEmptySubsequences: false)
        guard pieces.count > parts, !pieces[0].isEmpty, pieces[0].allSatisfy(\.isNumber) else { return nil }
        return (pieces[..<parts].joined(separator: "_"), pieces[parts...].joined(separator: "_"))
    }

    /// A Django migration's id names its app, because each app counts from 0001: ("shop 0001", "initial").
    static func django(app: String, _ stem: String) -> (id: String, name: String)? {
        split(stem, parts: 1).map { ("\(app) \($0.id)", $0.name) }
    }

    /// How far down its chain each Alembic revision is, so they list in the order they apply.
    private static func depths(_ found: [File]) -> [String: Int] {
        let parents = Dictionary(found.map { ($0.key, $0.parents) }, uniquingKeysWith: { a, _ in a })
        var depth: [String: Int] = [:]
        func of(_ key: String, _ seen: Set<String>) -> Int {
            if let known = depth[key] { return known }
            let below = (parents[key] ?? []).filter { !seen.contains($0) }.map { of($0, seen.union([key])) + 1 }
            depth[key] = below.max() ?? 0
            return depth[key] ?? 0
        }
        for file in found { _ = of(file.key, []) }
        return depth
    }
}
