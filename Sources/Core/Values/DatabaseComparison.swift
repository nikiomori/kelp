import Foundation

/// How a branch's copy of a database differs from the database it copies (`db.diff`), table by table: the columns and
/// the number of rows. The rows themselves aren't compared.
public struct DatabaseComparison: Codable, Sendable, Equatable {
    /// The copy's name, the name of the database it copies, and the branch the copy is for.
    public var copy: String, original: String, branch: String
    /// Every table of either, by name.
    public var tables: [Table]
    public init(copy: String, original: String, branch: String, tables: [Table]) {
        self.copy = copy
        self.original = original
        self.branch = branch
        self.tables = tables
    }

    public struct Table: Codable, Sendable, Equatable {
        public enum Change: String, Codable, Sendable, CaseIterable {
            /// Added is only in the copy, dropped only in the original; changed has columns that differ.
            case same, changed, added, dropped
        }
        public var name: String, change: Change
        /// The columns that differ: "+ paid_at TEXT", "− note TEXT", "total INTEGER → REAL".
        public var columns: [String]
        /// The table's rows in the copy and in the original; nil where it isn't, or they couldn't be counted.
        public var rows: Int?, was: Int?
        public init(name: String, change: Change, columns: [String] = [], rows: Int? = nil, was: Int? = nil) {
            self.name = name
            self.change = change
            self.columns = columns
            self.rows = rows
            self.was = was
        }

        /// True when the table is the same in both, columns and rows.
        public var same: Bool { change == .same && rows == was }

        /// What differs, in words: "+ paid_at TEXT", "new table, 37 rows", "12 rows fewer".
        public var words: String {
            switch change {
            case .added: return "new table" + (rows.map { ", " + Self.rows($0) } ?? "")
            case .dropped: return "dropped" + (was.map { ", had " + Self.rows($0) } ?? "")
            case .same, .changed:
                let counted: String? =
                    if let rows, let was, rows != was {
                        Self.rows(abs(rows - was)) + (rows > was ? " more" : " fewer")
                    } else { nil }
                return (columns + [counted].compactMap { $0 }).joined(separator: ", ")
            }
        }

        static func rows(_ n: Int) -> String { n == 1 ? "1 row" : "\(n) rows" }
    }

    /// "shop for feature/paid-at": the copy, named as what it copies.
    public var title: String { "\(original) for \(branch)" }

    /// The tables that differ: those whose columns changed, then the new, the dropped, and those whose rows alone did.
    public var differing: [Table] {
        let order: [Table.Change] = [.changed, .added, .dropped, .same]
        return tables.filter { !$0.same }.sorted {
            (order.firstIndex(of: $0.change) ?? 0, $0.name) < (order.firstIndex(of: $1.change) ?? 0, $1.name)
        }
    }

    /// What `kelp db diff` prints and Copy as Text copies: the title, then a line for each table that differs, its
    /// name padded so what differs lines up.
    public var text: String {
        let differ = differing
        guard !differ.isEmpty else {
            return "\(title) against \(original)\nNo differences in \(tables.count) tables' columns and rows."
        }
        let width = differ.map(\.name.count).max() ?? 0
        let lines = differ.map { $0.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.words }
        return (["\(title) against \(original)"] + lines).joined(separator: "\n")
    }
}
