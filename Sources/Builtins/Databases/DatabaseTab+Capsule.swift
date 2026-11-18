import AppKit
import Core
import DesignKit
import KelpKit

/// Where you are, over the rows: the environment's tag, then the server, the database and what's shown. A click opens
/// the database's menu.
extension DatabaseTab {
    // MARK: The capsule

    var database: DatabaseInfo? {
        let event = app.latest(DatabasesEvent.self, address.worktree)
        return (event?.databases ?? []).first { $0.name == address.name }
            ?? (event?.library ?? []).first { $0.name == address.name }
    }
    var engine: DatabaseInfo.Engine { database?.engine ?? .sqlite }

    func capsuleChanged() {
        let db = database
        let place: String? =
            switch mode {
            case .table(let table): table
            case .run: String(localized: "an agent’s run")
            case .query: String(localized: "Query")
            }
        let parts = [
            version ?? db.map { $0.engine.displayName },
            db?.database ?? db?.path.map { ($0 as NSString).lastPathComponent } ?? address.name,
            db?.ssh.map { String(localized: "via \($0)") }, place
        ]
        capsule.stringValue = parts.compactMap { $0 }.joined(separator: " · ")
        // VoiceOver hears the environment too: its tag is a view of its own inside the button.
        let stage = db.flatMap(DatabaseLook.shownStage).map { DatabaseLook.title($0) }
        let shown = [stage, capsule.stringValue].compactMap { $0 }.joined(separator: " · ")
        capsuleButton.setAccessibilityLabel(String(localized: "Connection: \(shown)"))
        // The environment shows as a tag, as in the databases list, and the rest stays quiet, because a whole red line
        // read as an error.
        capsuleBox.setViews([db.flatMap(DatabaseLook.stageChip), capsule, NSView()].compactMap { $0 }, in: .leading)
    }

    func askVersion() async {
        guard let db = database else { return }
        let check = await app.quiet(
            DatabaseCheck(worktreeId: address.worktree, database: db, versionOnly: true), timeout: 30)
        version = check?.version
        capsuleChanged()
    }

    func capsuleClicked() {
        guard let db = database else { return }
        let menu = NSMenu()
        let library =
            app.latest(DatabasesEvent.self, address.worktree)?.library?.contains { $0.name == db.name } ?? false
        DatabaseMenu.fill(menu, db, app: app, worktreeId: address.worktree, library: library)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: capsuleBox.bounds.height + 4), in: capsuleBox)
    }

    /// What the tab shows now: "orders · shop", "Query · shop", or the database alone for an agent's run.
    static func title(_ database: String, showing mode: Mode) -> String {
        switch mode {
        case .table(let table): "\(table) · \(database)"
        case .query: String(localized: "Query") + " · " + database
        case .run: database
        }
    }
}

/// What the tab strip calls a database's tab. It is observed, so the shell follows it as the tab shows another
/// table or a query.
@MainActor @Observable
final class DatabaseTabName {
    var title: String
    init(_ title: String) { self.title = title }
}
