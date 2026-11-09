import Core
import Foundation

extension Main {
    static let dbUsage = """
        db list | schema [table] [--db name] | query <sql> [--db name] [--limit 200] [--json]
           | open [name] | copy [name]
        """

    /// `db <action>`: the project's databases through kelpd, which holds their passwords (`db.*`).
    static func db(_ sub: String?, _ c: RPCClient) async throws {
        let worktree = try await currentWorktree(c)
        let named = flag("--db")
        switch sub {
        case "list":
            let all = try await c.call(DatabaseList(worktreeId: worktree.id))
            guard !all.isEmpty else {
                print("No databases here: Kelp looks in compose files, .env, config/database.yml and SQLite files.")
                return
            }
            print(
                table(
                    ["name", "engine", "where", "agents"],
                    all.map { [$0.name, $0.engine.rawValue, place($0), words($0)] }))
        case "schema":
            let name = try await database(named, worktree.id, c)
            let schema = try await c.call(
                DatabaseSchemaRead(worktreeId: worktree.id, database: name, table: args.first))
            print(text(schema, columns: args.first != nil || schema.tables.count <= 8))
        case "query":
            let json = has("--json"), limit = flag("--limit").flatMap(Int.init)
            guard !args.isEmpty else { fail("kelp db query \"SELECT …\" [--db name] [--limit 200] [--json]") }
            let name = try await database(named, worktree.id, c)
            let result = try await c.call(
                DatabaseQuery(worktreeId: worktree.id, database: name, sql: args.joined(separator: " "), limit: limit))
            if json {
                for row in result.rows {
                    show(
                        JSONValue.object(
                            Dictionary(
                                zip(result.columns, row.map { $0.map(JSONValue.string) ?? .null }),
                                uniquingKeysWith: { a, _ in a })))
                }
            } else if !result.columns.isEmpty {
                print(table(result.columns, result.rows.map { $0.map { cell($0) } }))
            }
            print(footer(result))
        case "copy":   // the user's: a copy for this workspace's branch (not for agents: `db.copy` isn't theirs)
            let name = try await database(args.first ?? named, worktree.id, c)
            let copy = try await c.call(DatabaseCopy(worktreeId: worktree.id, database: name))
            print("\(copy.name): \(copy.address)")
        case "open":
            let name = try await database(args.first ?? named, worktree.id, c)
            _ = try await c.call(UIOpen(uri: "db:\(worktree.id)/\(name)", split: "right", worktreeId: worktree.id))
        default: fail("usage: kelp " + dbUsage)
        }
    }

    /// The one named, or the only one; with several, the user's choice is asked for.
    static func database(_ named: String?, _ worktreeId: String, _ c: RPCClient) async throws -> String {
        if let named { return named }
        let all = try await c.call(DatabaseList(worktreeId: worktreeId))
        if all.count == 1 { return all[0].name }
        if all.isEmpty { fail("No databases here: kelp db list") }
        fail("Which one? --db " + all.map(\.name).joined(separator: " | "))
    }

    static func place(_ db: DatabaseInfo) -> String {
        [
            db.source ?? "added by hand",
            db.engine == .sqlite ? nil : "\(db.host ?? "?"):\(db.port.map(String.init) ?? "?")"
        ]
        .compactMap { $0 }.joined(separator: " ")
    }

    static func words(_ db: DatabaseInfo) -> String {
        let access =
            switch db.agentAccess {
            case .hidden: "hidden"
            case .read: "read only"
            case .ask: "read, ask to change"
            case .free: "read, change freely"
            }
        return db.production ? access + " (production)" : access
    }

    /// A cell as one short line: NULL spelled out, newlines shown, past 200 characters cut.
    static func cell(_ value: String?) -> String {
        guard let value else { return "NULL" }
        let line = value.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: " ")
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    /// Columns padded to their widest cell (up to 40), two spaces apart.
    static func table(_ header: [String], _ rows: [[String]]) -> String {
        let widths = header.indices.map { i in
            min(40, ([header[i]] + rows.map { i < $0.count ? $0[i] : "" }).map(\.count).max() ?? 0)
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, cell in
                i == cells.count - 1 || i >= widths.count
                    ? cell : cell.padding(toLength: max(widths[i], cell.count), withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        return ([line(header)] + rows.map(line)).joined(separator: "\n")
    }

    static func footer(_ r: QueryResult) -> String {
        if let changed = r.changed, r.columns.isEmpty {
            return "\(changed) \(changed == 1 ? "row" : "rows") changed · \(r.ms) ms"
        }
        let rows = r.total == 1 ? "1 row" : "\(r.total) rows"
        let cut = r.rows.count < r.total ? ", the first \(r.rows.count) shown (--limit for more)" : ""
        return "\(rows)\(cut) · \(r.ms) ms"
    }

    /// Tables a line each with their rows; with `columns`, each column under its table.
    static func text(_ schema: DatabaseSchema, columns: Bool) -> String {
        schema.tables.map { t in
            let head = t.name + (t.rows.map { "  \($0) rows" } ?? "")
            guard columns else { return head }
            let cols = t.columns.map { c in
                let marks = [c.primary ? "pk" : nil, c.nullable ? "null" : nil, c.references.map { "→ " + $0 }]
                    .compactMap { $0 }.joined(separator: " ")
                return "  " + [c.name, c.type, marks].filter { !$0.isEmpty }.joined(separator: "  ")
            }
            let indexes = t.indexes.isEmpty ? [] : ["  indexes: " + t.indexes.joined(separator: ", ")]
            return ([head] + cols + indexes).joined(separator: "\n")
        }.joined(separator: columns ? "\n\n" : "\n")
    }
}
