import Foundation

/// A database's migrations, read from the table its migration tool keeps (Rails' schema_migrations, Prisma's
/// _prisma_migrations…) and the tool's folder in the project, so the ones not applied yet show. Kelp only reads them.
public struct DatabaseMigrations: Codable, Sendable, Equatable {
    /// The tool's table, as the schema names it. The tab lists it under Migrations instead of among the tables.
    public var table: String
    /// Every migration either side knows of, oldest first.
    public var all: [Migration]
    public init(table: String, all: [Migration]) {
        self.table = table
        self.all = all
    }

    public struct Migration: Codable, Sendable, Equatable {
        /// The migration's version or number ("20261122", "0003") and the rest of its name ("add_paid_at").
        public var id: String, name: String
        public var applied: Bool
        public init(id: String, name: String, applied: Bool) {
            self.id = id
            self.name = name
            self.applied = applied
        }
    }

    public var notApplied: [Migration] { all.filter { !$0.applied } }

    /// "2 migrations not applied: 20261122 add_paid_at, 20261124 backfill_paid_at", or that all are, for
    /// `kelp db schema`.
    public var line: String {
        let left = notApplied
        guard !left.isEmpty else { return "Migrations (\(table)): all \(all.count) applied" }
        let named = left.map { [$0.id, $0.name].filter { !$0.isEmpty }.joined(separator: " ") }
        return "\(Self.count(left.count)) not applied (\(table)): " + named.joined(separator: ", ")
    }

    /// "1 migration", "2 migrations".
    public static func count(_ n: Int) -> String { n == 1 ? "1 migration" : "\(n) migrations" }
}
