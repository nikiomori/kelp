import AppKit
import Core
import DesignKit
import KelpKit

/// Adds a database by hand, or edits one added so: its address as a URL (postgres://user@host:5432/db, mysql://…, or
/// a SQLite file), a password that goes to the keychain, a name, what agents may do with it, and whether it's
/// production. A found one needs none of this: its menu changes what agents may do.
@MainActor
final class DatabaseSheet: NSObject, NSTextFieldDelegate {
    private let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: Metrics.sheetWidth, height: 10), styleMask: [.titled],
        backing: .buffered, defer: true)
    private let address = NSTextField(), password = NSSecureTextField(), name = NSTextField()
    private let agents = NSSegmentedControl(
        labels: DatabaseInfo.Access.allCases.map(DatabaseLook.title), trackingMode: .selectOne, target: nil,
        action: nil)
    private let production = NSButton(checkboxWithTitle: String(localized: "Production"), target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let save = NSButton()
    private var nameTyped = false

    /// Shown on the front window; saved when the user adds it.
    static func run(_ app: AppModel, worktreeId: String, editing: DatabaseInfo?) async {
        let sheet = DatabaseSheet(editing)
        guard await runSheet(sheet.window) == .OK, let db = sheet.database else { return }
        let typed = sheet.password.stringValue
        _ = await app.call(
            DatabaseSave(worktreeId: worktreeId, database: db, password: typed.isEmpty && editing != nil ? nil : typed))
    }

    private init(_ editing: DatabaseInfo?) {
        super.init()
        let title = NSTextField(
            labelWithString: editing == nil ? String(localized: "Add Database") : editing?.name ?? "")
        title.font = .ui(13, weight: .semibold)
        address.placeholderString = "postgres://app@localhost:5432/app_dev"
        address.delegate = self
        name.delegate = self
        password.placeholderString = editing == nil ? "" : String(localized: "Unchanged")
        agents.target = self
        agents.action = #selector(changed)
        production.target = self
        production.action = #selector(changed)
        note.font = .ui(11)
        note.textColor = .secondaryLabelColor
        let grid = SheetForm.grid([
            (String(localized: "URL"), address), (String(localized: "Password"), password),
            (String(localized: "Name"), name), (String(localized: "Agents"), agents), ("", production)
        ])
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        save.title = editing == nil ? String(localized: "Add") : String(localized: "Save")
        save.bezelStyle = .push
        save.keyEquivalent = "\r"
        save.target = self
        save.action = #selector(saved)
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.spacing = Metrics.gapWide
        window.contentView = SheetForm.stack(
            [title, grid, note, buttons], wide: [note, buttons], width: Metrics.sheetWidth)
        window.initialFirstResponder = address
        if let editing {
            address.stringValue = editing.engine == .sqlite ? editing.path ?? "" : editing.address
            name.stringValue = editing.name
            nameTyped = true
            production.state = editing.production ? .on : .off
        }
        agents.selectedSegment = DatabaseInfo.Access.allCases.firstIndex(of: editing?.access ?? .ask) ?? 2
        changed()
    }

    /// What the fields say, or nil while they don't name a database.
    var database: DatabaseInfo? {
        guard var db = Self.parse(address.stringValue) else { return nil }
        let typed = name.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { db.name = typed }
        db.access = DatabaseInfo.Access.allCases[max(0, agents.selectedSegment)]
        db.production = production.state == .on
        return db
    }

    /// A URL, or a path to a SQLite file; a password in the URL moves to the password field.
    static func parse(_ text: String) -> DatabaseInfo? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let path = (text as NSString).expandingTildeInPath
            let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return base.isEmpty ? nil : DatabaseInfo(name: base, engine: .sqlite, path: path)
        }
        guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(), let host = url.host,
            !host.isEmpty
        else { return nil }
        let engine: DatabaseInfo.Engine
        switch scheme {
        case "postgres", "postgresql": engine = .postgres
        case "mysql", "mariadb": engine = .mysql
        default: return nil
        }
        let database = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return DatabaseInfo(
            name: database.isEmpty ? host : database, engine: engine, host: host,
            port: url.port ?? (engine == .postgres ? 5432 : 3306), database: database.isEmpty ? nil : database,
            user: url.user)
    }

    func controlTextDidChange(_ n: Notification) {
        if n.object as? NSTextField === name { nameTyped = !name.stringValue.isEmpty }
        if n.object as? NSTextField === address {
            if let parts = URLComponents(string: address.stringValue), let secret = parts.password {
                password.stringValue = secret.removingPercentEncoding ?? secret
                var plain = parts
                plain.password = nil
                address.stringValue = plain.string ?? address.stringValue
            }
            if !nameTyped { name.stringValue = Self.parse(address.stringValue)?.name ?? "" }
        }
        changed()
    }

    /// Production holds agents to reading; the note says what the choice means and where the password goes.
    @objc private func changed() {
        let db = database
        save.isEnabled = db != nil && !(db?.name.isEmpty ?? true)
        let host = db?.host ?? "localhost"
        if production.state == .off, db != nil, !["localhost", "127.0.0.1", "::1"].contains(host), db?.engine != .sqlite
        {
            note.stringValue = String(
                localized: "\(host) isn't on this Mac: turn on Production unless it's a copy you can break.")
        } else if production.state == .on {
            note.stringValue = String(localized: "Production: agents only read it, whatever Agents says.")
        } else {
            note.stringValue = String(localized: "The password goes to the keychain. Agents get the name only.")
        }
    }

    @objc private func saved() { window.sheetParent?.endSheet(window, returnCode: .OK) }
    @objc private func cancelled() { window.sheetParent?.endSheet(window, returnCode: .cancel) }
}
