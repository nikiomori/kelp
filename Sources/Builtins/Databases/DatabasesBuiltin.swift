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
                    Task { await DatabaseOpener.run(app, worktreeId: workspace) }
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
                            SettingKeys.databaseAccess, "Agents may", "enum",
                            "With a database Kelp finds in a project, until its menu says otherwise. "
                                + "Production: read only.",
                            options: ["read", "ask", "free"],
                            labels: ["read": "Read", "ask": "Read, ask to change", "free": "Read and change"]),
                        s(
                            SettingKeys.databaseRows, "Rows an agent gets", "number",
                            "A statement's rows an agent reads unless it asks for more; the tab shows up to 1000.",
                            range: [10, 1000]),
                        s(
                            SettingKeys.databaseDensity, "Rows", "enum",
                            "How tall a table's rows are: Compact fits the most, as TablePlus does.",
                            options: ["compact", "normal", "comfortable"],
                            labels: ["compact": "Compact", "normal": "Normal", "comfortable": "Comfortable"]),
                        s(
                            SettingKeys.databaseTimeout, "Seconds a read may take", "number",
                            "Postgres and MySQL stop a read past it.", range: [1, 300])
                    ], keywords: ["SQL", "Postgres", "MySQL", "SQLite"], order: 75)
            ],
            tabs: [TabProvider(schemes: [TabURI.databaseScheme]) { DatabaseTab(uri: $0, app: app) }],
            // "+" and the empty workspace offer Database where the workspace has one: its databases are followed while it's
            // on screen (the daemon reads them again only when a file that names one changes).
            launched: [{ DatabaseFollow.start(app) }]
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

/// The words and marks a database shows with, the same in the panel and the tab.
enum DatabaseLook {
    static let symbol = "cylinder.split.1x2"

    static func engine(_ e: DatabaseInfo.Engine) -> String {
        switch e {
        case .sqlite: "SQLite"
        case .postgres: "Postgres"
        case .mysql: "MySQL"
        case .duckdb: "DuckDB"
        case .appwrite: "Appwrite"
        }
    }

    /// The engine's mark: its colour (as its project draws it) with two letters, the size of a row's icon.
    @MainActor static func badge(_ e: DatabaseInfo.Engine, size: CGFloat = 12) -> NSImage {
        let (hex, letters, dark): (String, String, Bool) =
            switch e {
            case .postgres: ("336791", "PG", false)
            case .mysql: ("00758F", "My", false)
            case .sqlite: ("4A7BAB", "SQ", false)
            case .duckdb: ("E8C400", "DK", true)
            case .appwrite: ("FD366E", "AW", false)
            }
        nonisolated(unsafe) let text = NSAttributedString(
            string: letters,
            attributes: [.font: NSFont.ui(size * 0.42, weight: .bold), .foregroundColor: dark ? NSColor.black : .white])
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            (NSColor(hex: hex) ?? .systemBlue).setFill()
            NSBezierPath(roundedRect: rect, xRadius: size / 4, yRadius: size / 4).fill()
            guard size >= 16 else { return true }
            let fit = text.size()
            text.draw(at: NSPoint(x: rect.midX - fit.width / 2, y: rect.midY - fit.height / 2))
            return true
        }
        image.accessibilityDescription = engine(e)
        return image
    }

    /// The app's own icon where it's installed, else a symbol: for Import's rows.
    @MainActor static func appIcon(_ source: String) -> NSImage {
        let bundles = [
            "tableplus": "com.tinyapp.TablePlus", "dbeaver": "org.jkiss.dbeaver.core.product",
            "datagrip": "com.jetbrains.datagrip", "sequelace": "com.sequel-ace.sequel-ace",
            "beekeeper": "io.beekeeperstudio.desktop", "dbgate": "org.dbgate", "pgadmin": "org.pgadmin.pgadmin4",
            "navicat": "com.navicat.NavicatPremium"
        ]
        if let id = bundles[source], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return .symbol(source.hasPrefix("pg") || source == "mycnf" ? "doc.text" : symbol)
    }

    /// The environment's word, as a menu and a segment say it.
    static func title(_ stage: DatabaseInfo.Stage) -> String {
        switch stage {
        case .local: String(localized: "Local")
        case .development: String(localized: "Development")
        case .staging: String(localized: "Staging")
        case .production: String(localized: "Production")
        }
    }

    /// What the environment changes, in a line: shown under its name wherever it's picked.
    static func meaning(_ stage: DatabaseInfo.Stage) -> String {
        switch stage {
        case .local: String(localized: "On this Mac. Agents do what Agents says; your saves go straight in.")
        case .development: String(localized: "A shared server for development: the same rules as Local.")
        case .staging: String(localized: "Agents ask you before each change.")
        case .production: String(localized: "Agents only read it. Your saves show their SQL and ask first.")
        }
    }

    /// What agents may do with it, in a line.
    static func meaning(_ access: DatabaseInfo.Access) -> String {
        switch access {
        case .hidden: String(localized: "Agents don't see it.")
        case .read: String(localized: "Agents read it; a change is refused.")
        case .ask: String(localized: "Agents read it; each change waits for your Allow.")
        case .free: String(localized: "Agents read and change it without asking.")
        }
    }

    /// Green, blue, orange, red: as TablePlus and TablePro colour theirs.
    static func color(_ stage: DatabaseInfo.Stage) -> NSColor {
        switch stage {
        case .local: .systemGreen
        case .development: .systemBlue
        case .staging: .systemOrange
        case .production: .systemRed
        }
    }

    /// The environment a list shows: what the user said, else Local for a file or this Mac's server. A server elsewhere
    /// nobody tagged shows none (Production is only ever the user's word; Local there would be wrong).
    static func shownStage(_ db: DatabaseInfo) -> DatabaseInfo.Stage? {
        if db.production { return .production }
        if let said = db.environment { return said }
        guard !db.engine.isFile, db.ssh != nil || db.host.map({ !DatabaseForm.onThisMac($0) }) == true else {
            return .local
        }
        return nil
    }

    /// "LOCAL", "DEV", "STAGING", "PROD" on a tinted capsule, wherever a database is listed; none when nobody said.
    @MainActor static func stageChip(_ db: DatabaseInfo) -> NSView? {
        guard let stage = shownStage(db) else { return nil }
        let word: String =
            switch stage {
            case .local: String(localized: "LOCAL")
            case .development: String(localized: "DEV")
            case .staging: String(localized: "STAGING")
            case .production: String(localized: "PROD")
            }
        let label = NSTextField(labelWithString: word)
        label.font = .ui(9, weight: .bold)
        label.textColor = color(stage)
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = Metrics.radiusXS
        chip.layer?.backgroundColor = color(stage).withAlphaComponent(0.16).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -1)
        ])
        chip.toolTip = title(stage) + ": " + meaning(stage)
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        return chip
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

    /// What agents may do, as the panel's icon: not see it, read it, ask to change it, change it.
    static func accessSymbol(_ access: DatabaseInfo.Access) -> String {
        switch access {
        case .hidden: "eye.slash"
        case .read: "eye"
        case .ask: "hand.raised"
        case .free: "pencil"
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
        let place = db.engine.isFile ? nil : db.host.map { ($0 == "localhost" ? "" : $0) + ":\(db.port ?? 0)" }
        return [engine(db.engine), db.source ?? String(localized: "added by hand"), place].compactMap { $0 }
            .joined(separator: " · ")
    }
}
