import AppKit
import Core
import DesignKit

/// The words and marks a database shows with, the same in the panel and the tab.
enum DatabaseLook {
    static let symbol = "cylinder.split.1x2"

    /// The engine's mark as Add Database draws it (`EnginePreset.badge`), at the size of a row's icon.
    @MainActor static func badge(_ engine: DatabaseInfo.Engine, size: CGFloat = 12) -> NSImage {
        let image = EnginePreset.of(engine).badge(size)
        image.accessibilityDescription = engine.displayName
        return image
    }

    /// The app's own icon when the app is installed, else a symbol. Import's rows show it.
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

    /// The environment's name, as a menu and a segment show it.
    static func title(_ stage: DatabaseInfo.Stage) -> String {
        switch stage {
        case .local: String(localized: "Local")
        case .development: String(localized: "Development")
        case .staging: String(localized: "Staging")
        case .production: String(localized: "Production")
        }
    }

    /// One line on what the environment changes, shown under its name wherever it is picked.
    static func meaning(_ stage: DatabaseInfo.Stage) -> String {
        switch stage {
        case .local: String(localized: "On this Mac. Agents do what Agents says; your saves go straight in.")
        case .development: String(localized: "A shared server for development: the same rules as Local.")
        case .staging: String(localized: "Agents ask you before each change.")
        case .production: String(localized: "Agents only read it. Your saves show their SQL and ask first.")
        }
    }

    /// One line on what agents may do with the database.
    static func meaning(_ access: DatabaseInfo.Access) -> String {
        switch access {
        case .hidden: String(localized: "Agents don't see it.")
        case .read: String(localized: "Agents read it; a change is refused.")
        case .ask: String(localized: "Agents read it; each change waits for your Allow.")
        case .free: String(localized: "Agents read and change it without asking.")
        }
    }

    /// Green, blue, orange and red, the way TablePlus and TablePro colour their environments.
    static func color(_ stage: DatabaseInfo.Stage) -> NSColor {
        switch stage {
        case .local: .systemGreen
        case .development: .systemBlue
        case .staging: .systemOrange
        case .production: .systemRed
        }
    }

    /// The environment a list shows: the one the user set, else Local for a file or a server on this Mac. A server
    /// elsewhere that nobody tagged shows none, because Production is only ever the user's word and Local would be
    /// wrong there.
    static func shownStage(_ db: DatabaseInfo) -> DatabaseInfo.Stage? {
        if db.production { return .production }
        if let said = db.environment { return said }
        guard !db.engine.isFile, db.ssh != nil || db.host.map({ !DatabaseInfo.isLocal($0) }) == true else {
            return .local
        }
        return nil
    }

    /// "LOCAL", "DEV", "STAGING" or "PROD" on a tinted capsule, wherever a database is listed; nil when it shows none.
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
        chip.layer?.backgroundColor = NSColor.fillTint(color(stage)).cgColor
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

    /// The symbol for what agents may do, as the panel's icon shows it: not see the database, read it, ask to change
    /// it, or change it.
    static func accessSymbol(_ access: DatabaseInfo.Access) -> String {
        switch access {
        case .hidden: "eye.slash"
        case .read: "eye"
        case .ask: "hand.raised"
        case .free: "pencil"
        }
    }

    /// What agents may do, worded as a menu or a segment shows it.
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
        return [db.engine.displayName, db.source ?? String(localized: "added by hand"), place].compactMap { $0 }
            .joined(separator: " · ")
    }
}
