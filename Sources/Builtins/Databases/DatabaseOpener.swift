import AppKit
import Core
import DesignKit
import KelpKit

/// Open Database (⌃⌘K), as TablePlus' ⌘K, in Open Quickly: a few letters find a database of the project or of All My
/// Projects; after a "/" ("agro/crops") they find a table of the one before it.
@MainActor
enum DatabaseOpener {
    static func show(_ app: AppModel, worktreeId: String) {
        /// The tables of the database named before the "/", read once.
        var tables: (database: String, load: Task<[DatabaseSchema.Table], Never>)?
        app.workbench.showList(
            String(localized: "Database, or database/table"),
            keys: String(localized: "↩ opens · / goes into a database's tables · ⎋ closes")
        ) { typed in
            let event = app.latest(DatabasesEvent.self, worktreeId)
            let everything = (event?.databases ?? []) + (event?.library ?? [])
            let text = typed.lowercased()
            let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let db = everything.first(where: { $0.name.lowercased().hasPrefix(parts[0]) })
            else {
                return everything.filter {
                    text.isEmpty
                        || [$0.name, $0.address, $0.group ?? ""].joined(separator: " ").lowercased().contains(text)
                }.map { database(app, worktreeId, $0) }
            }
            let load =
                tables?.database == db.name
                ? tables?.load
                : Task { await app.quiet(DatabaseSchemaRead(worktreeId: worktreeId, database: db.name))?.tables ?? [] }
            guard let load else { return [] }
            tables = (db.name, load)
            return await load.value.filter { parts[1].isEmpty || $0.name.lowercased().contains(parts[1]) }.prefix(200)
                .map { table(app, DatabaseURI(worktree: worktreeId, name: db.name, table: $0.name), $0) }
        }
    }

    private static func database(_ app: AppModel, _ worktreeId: String, _ db: DatabaseInfo) -> QuickItem {
        let uri = DatabaseURI(worktree: worktreeId, name: db.name).uri
        return QuickItem(
            db.name, detail: DatabasePanelRows.place(db) ?? db.engine.displayName,
            image: DatabaseLook.badge(db.engine, size: 18), accessory: { DatabaseLook.stageChip(db) },
            open: { app.workbench.open(uri) }, split: { app.workbench.open(uri, split: .right) })
    }

    private static func table(_ app: AppModel, _ at: DatabaseURI, _ table: DatabaseSchema.Table) -> QuickItem {
        QuickItem(
            table.name,
            detail: [at.name, table.rows.map { String(localized: "\($0) rows") }].compactMap { $0 }.joined(
                separator: " · "),
            icon: "tablecells", open: { app.workbench.open(at.uri) },
            split: { app.workbench.open(at.uri, split: .right) })
    }
}
