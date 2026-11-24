import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

extension Builtins {

    /// A project's databases, as its agents reach them (`kelp db`). It adds the Databases panel (what is there, what
    /// agents ran, who is asking) and a `db:` tab with a database's tables, a run's rows, and the user's own query.
    package static let databases = Builtin(
        "kelp.databases", "Databases", "The project’s databases: what agents ran on them, and their tables.",
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
                },
                // What the database tab in front does, each while its button shows. Save's ⌘S stays the button's own
                // key, not the command's default, which would take Save's key from the whole window. Filters has no
                // key: ⇧⌘F is Find in Project everywhere, and ⌥⌘F is Git: Fetch.
                tabCommand(app, "databases.run", "Run Statement", "cmd+return", shown: { $0.run }) { $0.runQuery() },
                tabCommand(app, "databases.explain", "Explain", shown: { $0.explain }) { $0.explainQuery() },
                tabCommand(app, "databases.filters", "Filters", shown: { $0.filterToggle }) {
                    $0.toggleFilters()
                },
                tabCommand(app, "databases.save", "Save Changes", shown: { $0.save }) { $0.saveEdits() },
                tabCommand(app, "databases.discard", "Discard Changes…", shown: { $0.discard }) { $0.discardEdits() },
                tabCommand(app, "databases.saveQuery", "Save Query…", shown: { $0.saveQuery }) { $0.keepQuery() },
                tabCommand(app, "databases.showSQL", "Show SQL", shown: { $0.showSQL }) { $0.showEdits() },
                tabCommand(app, "databases.addRow", "Add Row", shown: { $0.addRow }) { $0.grid.addRow() },
                tabCommand(app, "databases.refresh", "Refresh Database", shown: { $0.reload }) { $0.refresh() },
                tabCommand(app, "databases.details", "Details", shown: { $0.detailsToggle }) { $0.toggleDetails() },
                tabCommand(app, "databases.previousRows", "Previous Rows", shown: { $0.previous }) { $0.turn(-1) },
                tabCommand(app, "databases.nextRows", "Next Rows", shown: { $0.next }) { $0.turn(1) },
                tabCommand(app, "databases.columns", "Columns", shown: { $0.columnsButton }) { $0.columnsMenu() },
                tabCommand(app, "databases.copyRows", "Copy or Export Rows", shown: { $0.copyAs }) { $0.copyMenu() },
                tabCommand(app, "databases.newQuery", "New Query", shown: { $0.view }) { tab in
                    Task { await tab.leave(to: .query) }
                },
                tabCommand(app, "databases.showData", "Show Data", shown: { $0.part }) { $0.showPart(0) },
                tabCommand(app, "databases.showStructure", "Show Structure", shown: { $0.part }) { $0.showPart(1) }
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
                            "A statement’s rows an agent reads unless it asks for more; the tab shows up to 1000.",
                            range: [10, 1000]),
                        s(
                            SettingKeys.databaseDensity, "Table rows", .enum,
                            "How tall a table’s rows are: Compact fits the most, as TablePlus does.",
                            options: ["compact", "normal", "comfortable"],
                            labels: ["compact": "Compact", "normal": "Normal", "comfortable": "Comfortable"]),
                        s(
                            SettingKeys.databaseTimeout, "Seconds a read may take", .number,
                            "Postgres and MySQL stop a read past it.", range: [1, 300])
                    ], keywords: ["SQL", "Postgres", "MySQL", "SQLite"], order: 75)
            ],
            tabs: [
                TabProvider(
                    schemes: [TabURI.databaseScheme],
                    make: { uri in
                        DatabaseURI(uri)?.compare == nil
                            ? DatabaseTab(uri: uri, app: app) : DatabaseCompareTab(uri: uri, app: app) as TabContent
                    },
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

extension Builtins {
    /// A command for the database tab in front, enabled while its button (`shown`) shows there and can be pressed;
    /// elsewhere it beeps.
    fileprivate static func tabCommand(
        _ app: AppModel, _ id: String, _ title: String, _ key: String? = nil,
        shown: @escaping @MainActor (DatabaseTab) -> NSView, _ run: @escaping @MainActor (DatabaseTab) -> Void
    ) -> CommandSpec {
        CommandSpec(
            id: id, title: title, key: key,
            enabled: {
                (app.workbench.focusedContent as? DatabaseTab).map {
                    let button = shown($0)
                    return !button.isHiddenOrHasHiddenAncestor && (button as? NSControl)?.isEnabled != false
                } ?? false
            }
        ) { _ in
            guard let tab = app.workbench.focusedContent as? DatabaseTab else { return NSSound.beep() }
            run(tab)
        }
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

/// "db:<workspace>/<name>", with "?run=<id>" for one run's rows, "?table=<name>" for a table's rows, or
/// "?compare=<original>" for how a branch's copy differs from the database it copies (`DatabaseCompareTab`).
struct DatabaseURI: Equatable {
    var worktree: String, name: String
    var run: String?, table: String?, compare: String?
}

extension DatabaseURI {
    /// Parses the URI with `DatabaseTabURI.parts`, the same way the daemon reads it to check what an agent may open.
    init?(_ uri: String) {
        guard let parts = DatabaseTabURI.parts(uri) else { return nil }
        (worktree, name) = (parts.worktree, parts.name)
        let query = parts.query ?? ""
        run = query.hasPrefix("run=") ? String(query.dropFirst(4)) : nil
        table = query.hasPrefix("table=") ? String(query.dropFirst(6)).removingPercentEncoding : nil
        compare = query.hasPrefix("compare=") ? String(query.dropFirst(8)).removingPercentEncoding : nil
    }

    var uri: String { DatabaseTabURI.uri(worktree: worktree, name: name, run: run, table: table, compare: compare) }
}
