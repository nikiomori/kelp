import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

extension Builtins {

    /// A project's databases, as its agents reach them (`kelp db`): the Databases panel (what's there, what agents ran,
    /// who asks), and a `db:` tab with a database's tables, a run's rows, and a query of the user's own.
    package static let databases = Builtin(
        "kelp.databases", "Databases", "The project's databases: what agents ran on them, and their tables.",
        icon: DatabaseLook.symbol
    ) { app in
        return Contributions(
            panels: [
                PanelSpec(id: "databases", title: "Databases", icon: DatabaseLook.symbol, extensionId: "kelp.databases")
                {
                    DatabasesPanel(app: app)
                }
            ],
            editors: [
                EditorSpec(
                    id: "databases.open", title: "Database", icon: DatabaseLook.symbol,
                    available: { ctx in
                        ctx.workspace.map { app.latest(DatabasesEvent.self, $0.id)?.databases.isEmpty == false }
                            ?? false
                    },
                    uri: { ctx in
                        guard let wid = ctx.workspace?.id,
                            let first = app.latest(DatabasesEvent.self, wid)?.databases.first
                        else { return nil }
                        return DatabaseURI(worktree: wid, name: first.name).uri
                    })
            ],
            commands: [
                cmd("databases.open", "Open Database…", "ctrl+cmd+k") {
                    guard let workspace = app.workbench.workspaceId else { return NSSound.beep() }
                    DatabaseOpener.show(app, worktreeId: workspace)
                },
                cmd("databases.add", "Add Database…") {
                    guard let workspace = app.workbench.workspaceId else {
                        NSSound.beep()
                        return
                    }
                    Task { await DatabaseSheet.run(app, worktreeId: workspace, editing: nil) }
                }
            ],
            settings: [
                SettingsSection(
                    id: "databases", title: "Databases", icon: DatabaseLook.symbol,
                    specs: [
                        s(
                            SettingKeys.databaseAccess, "Agents may", .enum,
                            "With a database Kelp finds in a project, until its menu says otherwise. "
                                + "Production: read only.",
                            options: ["read", "ask", "free"],
                            labels: ["read": "Read", "ask": "Read, ask to change", "free": "Read and change"]),
                        s(
                            SettingKeys.databaseRows, "Rows an agent gets", .number,
                            "A statement's rows an agent reads unless it asks for more; the tab shows up to 1000.",
                            range: [10, 1000]),
                        s(
                            SettingKeys.databaseDensity, "Rows", .enum,
                            "How tall a table's rows are: Compact fits the most, as TablePlus does.",
                            options: ["compact", "normal", "comfortable"],
                            labels: ["compact": "Compact", "normal": "Normal", "comfortable": "Comfortable"]),
                        s(
                            SettingKeys.databaseTimeout, "Seconds a read may take", .number,
                            "Postgres and MySQL stop a read past it.", range: [1, 300])
                    ], keywords: ["SQL", "Postgres", "MySQL", "SQLite"], order: 75, tint: NSColor(hex: 0x5856D6))
            ],
            tabs: [
                TabProvider(
                    schemes: [TabURI.databaseScheme], make: { DatabaseTab(uri: $0, app: app) },
                    placeholder: { uri in
                        (DatabaseURI(uri).map(DatabaseTab.title) ?? TabURI.body(uri), .symbol(DatabaseLook.symbol), nil)
                    })
            ],
            // "+" and the empty workspace offer Database where the workspace has one: its databases are followed while it's
            // on screen (the daemon reads them again only when a file that names one changes).
            launched: [{ DatabaseFollow.start(app) }],
            skills: [databasesSkill]
        )
    }
}

/// The databases of the workspace on screen, kept watched while Kelp runs: what "+" offers reads them.
@MainActor
enum DatabaseFollow {
    private static var watched: Watched?

    static func start(_ app: AppModel) {
        let follow = Watched(.databases, in: app)
        watched = follow
        track {
            app.workbench.workspaceId
        } changed: {
            follow.key = $0
        }
    }
}

extension DatabasesEvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .databases }
}

extension TabURI {
    /// A database's tab (`DatabaseURI`; the daemon and `kelp db` build it with `DatabaseTabURI`).
    static let databaseScheme = "db"
}

/// "db:<workspace>/<name>", "?run=<id>" for one run's rows, "?table=<name>" for a table's.
struct DatabaseURI: Equatable {
    var worktree: String, name: String, run: String?, table: String?

    init(worktree: String, name: String, run: String? = nil, table: String? = nil) {
        self.worktree = worktree
        self.name = name
        self.run = run
        self.table = table
    }

    init?(_ uri: String) {
        guard TabURI.scheme(uri) == TabURI.databaseScheme else { return nil }
        let body = TabURI.body(uri).split(separator: "?", maxSplits: 1).map(String.init)
        let parts = body[0].split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        worktree = parts[0]
        name = parts[1].removingPercentEncoding ?? parts[1]
        run = body.count > 1 && body[1].hasPrefix("run=") ? String(body[1].dropFirst(4)) : nil
        table =
            body.count > 1 && body[1].hasPrefix("table=")
            ? String(body[1].dropFirst(6)).removingPercentEncoding : nil
    }

    var uri: String { DatabaseTabURI.uri(worktree: worktree, name: name, run: run, table: table) }
}
