import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

extension Builtins {

    /// A project's databases, as its agents reach them (`kelp db`). It adds the Databases panel (what is there, what
    /// agents ran, who is asking) and a `db:` tab with a database's tables, a run's rows, and the user's own query.
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
                            labels: ["read": "Read", "ask": "Read, Ask to Change", "free": "Read and Change"]),
                        s(
                            SettingKeys.databaseRows, "Rows an agent gets", .number,
                            "A statement's rows an agent reads unless it asks for more; the tab shows up to 1000.",
                            range: [10, 1000]),
                        s(
                            SettingKeys.databaseDensity, "Table rows", .enum,
                            "How tall a table's rows are: Compact fits the most, as TablePlus does.",
                            options: ["compact", "normal", "comfortable"],
                            labels: ["compact": "Compact", "normal": "Normal", "comfortable": "Comfortable"]),
                        s(
                            SettingKeys.databaseTimeout, "Seconds a read may take", .number,
                            "Postgres and MySQL stop a read past it.", range: [1, 300])
                    ], keywords: ["SQL", "Postgres", "MySQL", "SQLite"], order: 75)
            ],
            tabs: [
                TabProvider(
                    schemes: [TabURI.databaseScheme], make: { DatabaseTab(uri: $0, app: app) },
                    placeholder: { uri in
                        (DatabaseURI(uri).map(DatabaseTab.title) ?? TabURI.body(uri), .symbol(DatabaseLook.symbol), nil)
                    })
            ],
            // "+" and the empty workspace offer Database when the workspace has a database. So the databases are
            // followed while the workspace is on screen; the daemon reads them again only when a file naming one
            // changes.
            launched: [{ DatabaseFollow.start(app) }],
            skills: [databasesSkill]
        )
    }
}

/// Keeps the databases of the workspace on screen watched while Kelp runs, because what "+" offers reads them.
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
    /// The scheme of a database's tab (`DatabaseURI`); the daemon and `kelp db` build such URIs with `DatabaseTabURI`.
    static let databaseScheme = "db"
}

/// "db:<workspace>/<name>", with "?run=<id>" for one run's rows or "?table=<name>" for a table's rows.
struct DatabaseURI: Equatable {
    var worktree: String, name: String
    var run: String?, table: String?
}

extension DatabaseURI {
    /// Parses the URI with `DatabaseTabURI.parts`, the same way the daemon reads it to check what an agent may open.
    init?(_ uri: String) {
        guard let parts = DatabaseTabURI.parts(uri) else { return nil }
        (worktree, name) = (parts.worktree, parts.name)
        let query = parts.query ?? ""
        run = query.hasPrefix("run=") ? String(query.dropFirst(4)) : nil
        table = query.hasPrefix("table=") ? String(query.dropFirst(6)).removingPercentEncoding : nil
    }

    var uri: String { DatabaseTabURI.uri(worktree: worktree, name: name, run: run, table: table) }
}
