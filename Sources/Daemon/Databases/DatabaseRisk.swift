import Core
import Foundation

// What makes an asked change worth a second look (`ChangeRisk`): read from its text and its trial, with a count of
// what it takes away.

extension Databases {
    /// Returns what makes `sql` worth a second look before Allow, or nil for a plain change. `change` is what its trial
    /// does to its rows, as Kelp keeps it (nil when it can't tell), which says whether Undo This Change could put them
    /// back. The rows or values a DROP, TRUNCATE or dropped column takes are counted when the database answers soon.
    func risk(_ databaseConnection: DatabaseConnection, _ sql: String, change: RowChange?) async -> ChangeRisk? {
        guard let (found, counting) = Self.risk(sql, change: change) else { return nil }
        var risk = found
        // The count is made of the agent's own names, so it runs only as what the agent could run itself: one
        // statement, read-only, that stays in the database
        let engine = databaseConnection.database.engine
        guard let counting, SQLText.Reading.of(engine).allSatisfy({ SQLText.statements(counting, $0).count == 1 }),
            SQLText.pastTheDatabase(counting, engine) == nil
        else { return risk }
        do {
            let rows = try await DatabaseEngines.read(
                databaseConnection, counting, timeout: DatabaseTimes.risk, off: offloads)
            risk.values = rows.rows.first?.first.flatMap { $0 }.flatMap { Int($0) }
        } catch {
            Log.session.info("db risk count in \(databaseConnection.database.name) didn't run: \(error)")
        }
        return risk
    }

    /// A name as SQL writes it: quoted or bare, with its schema. (`\x3B` is a ";".)
    private static let name = #"((?:"[^"]+"|`[^`]+`|[^\s(,\x3B."`]+)(?:\.(?:"[^"]+"|`[^`]+`|[^\s(,\x3B."`]+))*)"#

    /// Reads the kind of risk from the statement's text, and the read that counts what it takes away.
    static func risk(_ sql: String, change: RowChange?) -> (risk: ChangeRisk, counting: String?)? {
        let code = SQLText.code(SQLText.uncommented(sql, SQLText.Reading()))
        func match(_ pattern: String) -> [String]? {
            // swiftlint:disable:next force_try
            let regex = try! NSRegularExpression(pattern: "^" + pattern, options: .caseInsensitive)   // Kelp's own
            guard let found = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) else {
                return nil
            }
            let ranges = (1..<found.numberOfRanges).compactMap { Range(found.range(at: $0), in: code) }
            return ranges.map { String(code[$0]) }
        }
        let ifExists = #"(?:IF\s+EXISTS\s+)?"#
        if let found = match(
            #"ALTER\s+TABLE\s+"# + ifExists + #"(?:ONLY\s+)?"# + name + #"\s+DROP\s+(?:COLUMN\s+)?"#
                + ifExists + name),
            !["CONSTRAINT", "INDEX", "KEY", "PRIMARY", "FOREIGN", "CHECK", "PARTITION"].contains(found[1].uppercased())
        {
            return (
                ChangeRisk(kind: .dropColumn, table: found[0], column: found[1]),
                "SELECT count(\(found[1])) FROM \(found[0])"
            )
        }
        if let found = match(#"DROP\s+TABLE\s+"# + ifExists + name) {
            return (ChangeRisk(kind: .drop, table: found[0]), "SELECT count(*) FROM \(found[0])")
        }
        if let found = match(#"DROP\s+(?:MATERIALIZED\s+VIEW|\w+)\s+(?:CONCURRENTLY\s+)?"# + ifExists + name) {
            return (ChangeRisk(kind: .drop, table: found[0]), nil)
        }
        if let found = match(#"TRUNCATE\s+(?:TABLE\s+)?(?:ONLY\s+)?"# + name) {
            return (ChangeRisk(kind: .truncate, table: found[0]), "SELECT count(*) FROM \(found[0])")
        }
        guard SQLText.countsItsRows(sql), let table = table(sql, asWritten: true) else { return nil }
        // A WHERE or LIMIT in a string ('where') isn't one: strings are left out before looking
        let bare = code.replacing(/'(?:[^']|'')*'|"[^"]*"|`[^`]*`/, with: "''")
        if ["UPDATE", "DELETE"].contains(SQLText.verb(sql)),
            bare.range(of: #"\b(WHERE|LIMIT)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        {
            return (ChangeRisk(kind: .noWhere, table: table), nil)
        }
        return change?.undoable == true ? nil : (ChangeRisk(kind: .noUndo, table: table), nil)
    }
}
