import Core
import Foundation

/// Putting an agent's change back, from the rows Kelp kept of it (`QueryResult.change`): the read that says whether the
/// rows are still as the change left them, and the statements that restore them, one a row, each found by the table's
/// key.
enum DatabaseUndo {
    /// Why this change can't be put back; nil: it can. `readFailure`: the read of what Kelp kept failed (a timeout, no
    /// daemon), which isn't Kelp having let the rows go.
    static func refusal(_ result: QueryResult?, readFailure: String? = nil) -> String? {
        if let readFailure { return String(localized: "Can’t read what Kelp kept of this change: \(readFailure)") }
        guard let result else {
            return String(localized: "Kelp no longer keeps this change's rows: it keeps the latest changes only.")
        }
        guard let change = result.change else {
            return String(
                localized:
                    "Kelp puts back the rows of one table's UPDATE, DELETE or INSERT when it kept them all as they were: not this change."
            )
        }
        guard !key(result).isEmpty else {
            return String(localized: "\(change.tableName) has no primary key to find its rows by.")
        }
        if change.kind == .update, change.before == nil {
            return String(localized: "Kelp didn't keep these rows as they were before the change.")
        }
        return nil
    }

    /// Reads the change's rows as they are now, by their keys.
    static func check(_ result: QueryResult, _ engine: DatabaseInfo.Engine) -> String {
        let columns = result.columns.map(engine.quoted).joined(separator: ", ")
        let rows = result.rows.map { "(" + found($0, result, engine) + ")" }.joined(separator: " OR ")
        return "SELECT \(columns) FROM \(result.change?.table ?? "") WHERE \(rows)"
    }

    /// Whether the rows are as the change left them: an update's and an insert's still there and the same, a
    /// delete's still gone.
    static func unchanged(_ result: QueryResult, now: [[String?]]) -> Bool {
        guard let kind = result.change?.kind else { return false }
        if kind == .delete { return now.isEmpty }
        let at = key(result)
        let byKey = Dictionary(now.map { (values($0, at), $0) }, uniquingKeysWith: { first, _ in first })
        return now.count == result.rows.count && result.rows.allSatisfy { byKey[values($0, at)] == $0 }
    }

    /// What puts the rows back: an update's changed values as they were, a delete's rows again, an insert's rows gone.
    /// Each finds its row by its key and as the change left it (`unchanged` read it so before the question), so a row
    /// changed while the question was up changes nothing; `db.apply`'s `each: 1` then keeps none of them.
    static func statements(_ result: QueryResult, _ engine: DatabaseInfo.Engine) -> [String] {
        guard let change = result.change else { return [] }
        switch change.kind {
        case .update:
            return zip(change.before ?? [], result.rows).compactMap { was, now in
                let changed = result.columns.indices.filter {
                    was.indices.contains($0) && now.indices.contains($0) && was[$0] != now[$0]
                }
                let set = changed.map { "\(engine.quoted(result.columns[$0])) = \(engine.literal(was[$0]))" }
                guard !set.isEmpty else { return nil }
                let still = changed.map { holds($0, now[$0], result, engine) }.joined(separator: " AND ")
                return "UPDATE \(change.table) SET \(set.joined(separator: ", ")) WHERE \(found(now, result, engine))"
                    + " AND " + still
            }
        case .delete:
            let names = result.columns.map(engine.quoted).joined(separator: ", ")
            return result.rows.map { row in
                "INSERT INTO \(change.table) (\(names)) VALUES ("
                    + row.map { engine.literal($0) }.joined(separator: ", ") + ")"
            }
        case .insert:
            return result.rows.map { row in
                let still = result.columns.indices.filter { !key(result).contains($0) && row.indices.contains($0) }
                    .map { holds($0, row[$0], result, engine) }
                return "DELETE FROM \(change.table) WHERE "
                    + ([found(row, result, engine)] + still).joined(separator: " AND ")
            }
        }
    }

    /// The key's columns among the rows', by index; none unless all of them are there.
    private static func key(_ result: QueryResult) -> [Int] {
        let key = result.change?.key ?? []
        let at = key.compactMap(result.columns.firstIndex(of:))
        return at.count == key.count ? at : []
    }

    private static func values(_ row: [String?], _ at: [Int]) -> [String?] {
        at.map { row.indices.contains($0) ? row[$0] : nil }
    }

    /// "note" = 'x', or "note" IS NULL: the column holds this value.
    private static func holds(
        _ column: Int, _ value: String?, _ result: QueryResult, _ engine: DatabaseInfo.Engine
    ) -> String {
        engine.quoted(result.columns[column]) + (value == nil ? " IS NULL" : " = " + engine.literal(value))
    }

    /// "id" = '10' AND "day" = '2026-02-01': the row with this key.
    private static func found(_ row: [String?], _ result: QueryResult, _ engine: DatabaseInfo.Engine) -> String {
        let at = key(result)
        return zip(at, values(row, at)).map { "\(engine.quoted(result.columns[$0])) = \(engine.literal($1))" }
            .joined(separator: " AND ")
    }
}
