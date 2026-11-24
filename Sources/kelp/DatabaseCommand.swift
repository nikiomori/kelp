import Core
import Foundation

extension Main {
    static let dbUsage = """
        db list | schema [table] [--db name] | query <sql; sql…> [--db name] [--limit 200] [--json]
           | open [name] | copy [name] | diff [name]
        """

    /// `db <action>` works with the project's databases through kelpd, which holds their passwords (`db.*`).
    static func db(_ sub: String?, _ client: RPCClient) async throws {
        let worktree = try await currentWorktree(client)
        let named = flag("--db")
        switch sub {
        case "list":
            let all = try await client.call(DatabaseList(worktreeId: worktree.id))
            guard !all.isEmpty else {
                print("No databases here: Kelp looks in compose files, .env, config/database.yml and SQLite files.")
                return
            }
            print(
                table(
                    ["name", "engine", "where", "agents"],
                    all.map { [$0.name, $0.engine.rawValue, place($0), words($0)] }))
        case "schema":
            let name = try await database(named, worktree.id, client)
            let schema = try await client.call(
                DatabaseSchemaRead(worktreeId: worktree.id, database: name, table: args.first))
            print(text(schema, columns: args.first != nil || schema.tables.count <= 8))
        case "query":
            let json = has("--json"), limit = limitFlag()
            guard !args.isEmpty else { fail("kelp db query \"SELECT …\" [--db name] [--limit 200] [--json]") }
            let name = try await database(named, worktree.id, client)
            let sql = args.joined(separator: " ")
            let result = try await client.call(
                DatabaseQuery(worktreeId: worktree.id, database: name, sql: sql, limit: limit))
            if let parts = result.statements {   // Several statements in one transaction: what each changed.
                let said = batch(parts, changed: result.changed, ms: result.ms, json: json)
                print(said.rows)
                if json { FileHandle.standardError.write(Data((said.footer + "\n").utf8)) } else { print(said.footer) }
            } else if json {
                // Print one object per line (`jq` reads them as they come). The footer goes to stderr, out of the
                // rows' way.
                for row in result.rows { print(line(Self.object(result.columns, row))) }
                FileHandle.standardError.write(Data((footer(result, sql: sql, limit: limit) + "\n").utf8))
            } else {
                if !result.columns.isEmpty { print(table(result.columns, result.rows.map { $0.map { cell($0) } })) }
                print(footer(result, sql: sql, limit: limit))
            }
        case "copy":   // Only the user may copy a database for this branch (`db.copy` isn't open to agents).
            let name = try await database(args.first ?? named, worktree.id, client)
            let copy = try await client.call(DatabaseCopy(worktreeId: worktree.id, database: name))
            print("\(copy.name): \(copy.address)")
        case "diff":   // how this branch's copy differs from the database it copies: columns and row counts
            print(try await client.call(DatabaseDiff(worktreeId: worktree.id, database: args.first ?? named)).text)
        case "open":
            let name = try await database(args.first ?? named, worktree.id, client)
            _ = try await client.call(
                UIOpen(
                    uri: DatabaseTabURI.uri(worktree: worktree.id, name: name), split: "right", worktreeId: worktree.id)
            )
        default: fail("usage: kelp " + dbUsage)
        }
    }

    /// Returns the database named, or the only one. When there are several, it asks the user to choose.
    static func database(_ named: String?, _ worktreeId: String, _ client: RPCClient) async throws -> String {
        if let named { return named }
        let all = try await client.call(DatabaseList(worktreeId: worktreeId))
        if let one = unnamed(all) { return one }
        if all.isEmpty { fail("No databases here: kelp db list") }
        fail("Which one? --db " + all.map(\.name).joined(separator: " | "))
    }

    /// Returns the database meant when none is named: the only one there, counting this branch's copy in place of its
    /// original. nil when there is none, or several to pick from.
    static func unnamed(_ all: [DatabaseInfo]) -> String? {
        let own = all.filter { db in !all.contains { $0.copy?.of == db.name && $0.name != db.name } }
        return own.count == 1 ? own[0].name : nil
    }

    static func place(_ db: DatabaseInfo) -> String {
        [
            db.copy.map { "this branch's copy of \($0.of)" } ?? db.source ?? "added by hand",
            db.engine.isFile ? nil : "\(db.host ?? "?"):\(db.port.map(String.init) ?? "?")"
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

    /// Formats several statements run as one: a line for each with the rows it changed (an object for each with
    /// `json`), and the total they changed.
    static func batch(_ parts: [StatementResult], changed: Int?, ms: Int, json: Bool) -> (rows: String, footer: String)
    {
        let counts = parts.map { $0.changed.map(String.init) }
        let rows =
            json
            ? zip(parts, counts).map { line(object(["statement", "changed"], [$0.sql, $1])) }.joined(separator: "\n")
            : table(["statement", "changed"], zip(parts, counts).map { [cell($0.sql), $1 ?? "-"] })
        let all = changed.map { $0 == 1 ? "1 row" : "\($0) rows" } ?? "No rows"
        return (rows, "\(all) changed by \(parts.count) statements in one transaction · \(ms) ms")
    }

    /// Formats a cell as one short line, with NULL spelled out, newlines shown, and anything past 200 characters cut.
    static func cell(_ value: String?) -> String {
        guard let value else { return "NULL" }
        let line = value.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: " ")
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    /// Formats a table with columns padded to their widest cell (up to 40), two spaces apart.
    static func table(_ header: [String], _ rows: [[String]]) -> String {
        let widths = header.indices.map { column in
            min(40, ([header[column]] + rows.map { column < $0.count ? $0[column] : "" }).map(\.count).max() ?? 0)
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, cell in
                i == cells.count - 1 || i >= widths.count
                    ? cell : cell.padding(toLength: max(widths[i], cell.count), withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        return ([line(header)] + rows.map(line)).joined(separator: "\n")
    }

    /// Reads `--limit` as a count. A value that isn't a count fails the command rather than being read as the
    /// default.
    static func limitFlag() -> Int? {
        guard let text = flag("--limit") else { return nil }
        guard let limit = Int(text), limit >= 0 else { fail("--limit takes a count of rows: --limit 500") }
        return limit
    }

    /// Returns a row as a JSON object. A column named twice (`a.id, b.id`) keeps both, the second as `id_2`.
    static func object(_ columns: [String], _ row: [String?]) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for (column, value) in zip(columns, row) {
            var key = column, n = 2
            while object[key] != nil {
                key = "\(column)_\(n)"
                n += 1
            }
            object[key] = value.map(JSONValue.string) ?? .null
        }
        return .object(object)
    }

    /// Encodes a value as compact JSON on one line.
    static func line(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) } catch { return "null" }
    }

    /// Returns what the statement did: the rows a change touched (with the rows it returned, when it gives them), or
    /// else the rows read, how many of them are shown, and how to see more.
    static func footer(_ queryResult: QueryResult, sql: String, limit: Int?) -> String {
        if let changed = queryResult.changed {
            let verb = sql.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isLetter }.uppercased()
            guard changed > 0 || ["UPDATE", "DELETE", "INSERT", "MERGE", "REPLACE", "WITH"].contains(verb) else {
                return "Done · \(queryResult.ms) ms"   // DDL changed the schema, not rows.
            }
            let rows = changed == 1 ? "1 row" : "\(changed) rows"
            return "\(rows) changed" + (queryResult.columns.isEmpty ? "" : " (those rows above)")
                + " · \(queryResult.ms) ms"
        }
        let counted =
            queryResult.total >= QueryResult.counted
            ? "\(queryResult.total)+ rows" : queryResult.total == 1 ? "1 row" : "\(queryResult.total) rows"
        guard queryResult.rows.count < queryResult.total else { return "\(counted) · \(queryResult.ms) ms" }
        let more =
            if queryResult.cut == true {
                "Kelp keeps 1 MB of a result's cells: select fewer or shorter columns, or page with LIMIT and OFFSET"
            } else if queryResult.rows.count >= QueryResult.kept && (limit ?? 0) > queryResult.rows.count {
                "Kelp keeps \(QueryResult.kept) at most: narrow it with WHERE, or page with LIMIT and OFFSET"
            } else {
                "--limit for more"
            }
        return "\(counted), the first \(queryResult.rows.count) shown (\(more)) · \(queryResult.ms) ms"
    }

    /// Formats the tables, one per line with their rows, and with `columns`, each column under its table. The
    /// migrations not applied, when Kelp knows the database's migration tool, end it.
    static func text(_ schema: DatabaseSchema, columns: Bool) -> String {
        let tables = schema.tables.map { table in
            let head = table.name + (table.rows.map { "  \($0) rows" } ?? "")
            guard columns else { return head }
            let cols = table.columns.map { column in
                let marks = [
                    column.primary ? "pk" : nil, column.nullable ? "null" : nil, column.references.map { "→ " + $0 }
                ]
                .compactMap { $0 }.joined(separator: " ")
                return "  " + [column.name, column.type, marks].filter { !$0.isEmpty }.joined(separator: "  ")
            }
            let indexes = table.indexes.isEmpty ? [] : ["  indexes: " + table.indexes.joined(separator: ", ")]
            return ([head] + cols + indexes).joined(separator: "\n")
        }.joined(separator: columns ? "\n\n" : "\n")
        return [tables, schema.migrations?.line].compactMap { $0 }.joined(separator: "\n\n")
    }
}
