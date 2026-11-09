import AppKit
import Core
import KelpKit

extension Builtins {

    /// A project's databases, as its agents reach them (`kelp db`): the Databases panel (what's there, what agents ran,
    /// who asks), and a `db:` tab with a database's tables, a run's rows, and a query of the user's own.
    package static let databases = Builtin(
        "kelp.databases", "Databases", "The project's databases: what agents ran on them, and their tables.",
        icon: DatabaseLook.symbol
    ) { app in
        var contributions = Contributions()
        contributions.panels = [
            PanelSpec(id: "databases", title: "Databases", icon: DatabaseLook.symbol, extensionId: "kelp.databases") {
                DatabasesPanel(app: app)
            }
        ]
        contributions.tabs = [TabProvider(schemes: ["db"]) { DatabaseTab(uri: $0, app: app) }]
        contributions.commands = [
            cmd("databases.add", "Add Database…") {
                guard let workspace = app.workbench.workspaceId else {
                    NSSound.beep()
                    return
                }
                Task { await DatabaseSheet.run(app, worktreeId: workspace, editing: nil) }
            }
        ]
        return contributions
    }
}

extension DatabasesEvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .databases }
}

/// "db:<workspace>/<name>", and "?run=<id>" for one run's rows.
struct DatabaseURI: Equatable {
    var worktree: String, name: String, run: String?

    init(worktree: String, name: String, run: String? = nil) {
        self.worktree = worktree
        self.name = name
        self.run = run
    }

    init?(_ uri: String) {
        guard uri.hasPrefix("db:") else { return nil }
        let body = uri.dropFirst(3).split(separator: "?", maxSplits: 1).map(String.init)
        let parts = body[0].split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        worktree = parts[0]
        name = parts[1].removingPercentEncoding ?? parts[1]
        run = body.count > 1 && body[1].hasPrefix("run=") ? String(body[1].dropFirst(4)) : nil
    }

    var uri: String {
        let name = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return "db:\(worktree)/\(name)" + (run.map { "?run=" + $0 } ?? "")
    }
}

/// The words and marks a database shows with, the same in the panel and the tab.
enum DatabaseLook {
    static let symbol = "cylinder.split.1x2"

    static func engine(_ e: DatabaseInfo.Engine) -> String {
        switch e {
        case .sqlite: "SQLite"
        case .postgres: "Postgres"
        case .mysql: "MySQL"
        }
    }

    /// What agents may do, in a word for a chip.
    static func access(_ db: DatabaseInfo) -> String {
        switch db.agentAccess {
        case .hidden: String(localized: "hidden")
        case .read: String(localized: "read")
        case .ask: String(localized: "ask")
        case .free: String(localized: "free")
        }
    }

    /// The same as a menu or a segment says it.
    static func title(_ access: DatabaseInfo.Access) -> String {
        switch access {
        case .hidden: String(localized: "Can't See")
        case .read: String(localized: "Read")
        case .ask: String(localized: "Ask to Change")
        case .free: String(localized: "Change Freely")
        }
    }

    /// "Postgres · compose.yaml · :5432", "SQLite · db/test.sqlite3".
    static func detail(_ db: DatabaseInfo) -> String {
        let place = db.engine == .sqlite ? nil : db.host.map { ($0 == "localhost" ? "" : $0) + ":\(db.port ?? 0)" }
        return [engine(db.engine), db.source ?? String(localized: "added by hand"), place].compactMap { $0 }
            .joined(separator: " · ")
    }
}
