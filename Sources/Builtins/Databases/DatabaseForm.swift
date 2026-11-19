import AppKit
import Core
import DesignKit
import KelpKit

/// The form of Add Database. It shows only the engine's own fields (a file's path, or host, port, user, password and
/// database), with SSH and SSL folded until they're wanted. Then come the database's name, where it is kept, what
/// agents may do, and Production with why. The form connects by itself once typing pauses (`db.check`), and the line
/// at its foot says what it found or gives the server's words. Add works without a passing check, because a server
/// may be down for now.
@MainActor
final class DatabaseForm: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
    private unowned let sheet: DatabaseSheet
    private let engine: DatabaseInfo.Engine
    private let editing: DatabaseInfo?, container: String?
    private let host = NSTextField(), port = NSTextField(), user = NSTextField(), password = NSSecureTextField()
    private let database = NSComboBox(), path = NSTextField(), name = NSTextField()
    private let ssh = NSComboBox(), ssl = NSPopUpButton()
    private let sshRow = NSStackView(), sslRow = NSStackView()
    private let sshOn = NSButton(), sslOn = NSButton()
    private let place = CapsuleSegments(labels: [], name: String(localized: "Where It’s Listed"))
    private let agents = CapsuleSegments(labels: [], name: String(localized: "Agents"))
    private let stage = CapsuleSegments(
        labels: DatabaseInfo.Stage.allCases.map(DatabaseLook.title), name: String(localized: "Database Stage"))
    private let why = DatabaseSheet.small("")
    /// Says what agents may do with the database as the form stands. Under Production agents only read, whatever the
    /// choice says.
    private let agentsWhy = DatabaseSheet.small("")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let add = NSButton()
    private var nameTyped = false
    private var checking: Task<Void, Never>?
    private(set) var view = NSView()
    /// The field focused first: the host (or file) for a new database, the password for one pasted, picked or edited.
    var firstField: NSView { engine.isFile ? path : fresh ? host : password }
    private let fresh: Bool

    private let preset: EnginePreset?
    /// True when the database is edited from All My Projects, so it is kept there.
    private let inLibrary: Bool
    private var whyRow: NSGridRow?

    init(
        sheet: DatabaseSheet, address: DatabaseAddress, editing: DatabaseInfo?, container: String?,
        preset: EnginePreset? = nil, library: Bool = false
    ) {
        self.sheet = sheet
        self.preset = preset
        self.inLibrary = library
        engine = address.database.engine
        self.editing = editing
        self.container = container
        fresh = editing == nil && address.database.name.isEmpty
        super.init()
        build(address)
    }

    // MARK: Building

    private func build(_ address: DatabaseAddress) {
        let db = address.database
        let title = NSTextField(labelWithString: editing?.name ?? preset?.name ?? engine.displayName)
        title.font = .ui(TextSize.body, weight: .semibold)
        let mark = preset?.badge(22) ?? DatabaseLook.badge(engine, size: 18)
        let heading = NSStackView(views: [NSImageView(image: mark), title])
        heading.spacing = Metrics.gapWide
        for field in [host, port, user, password, path, name] { field.delegate = self }
        for combo in [database, ssh] {
            combo.delegate = self
            combo.completes = true
        }
        host.stringValue = db.host ?? ""
        port.stringValue = db.port.map(String.init) ?? ""
        let appwrite = engine == .appwrite
        port.placeholderString = engine.defaultPort.map(String.init) ?? ""
        if appwrite { host.placeholderString = "https://appwrite.example.com" }
        port.widthAnchor.constraint(equalToConstant: 64).isActive = true
        user.stringValue = db.user ?? ""
        user.placeholderString =
            appwrite ? String(localized: "Project ID") : engine == .postgres ? NSUserName() : "root"
        password.stringValue = address.password ?? ""
        password.placeholderString =
            editing?.passwordIn != nil
            ? String(localized: "Read from the app it came from when opened")
            : editing != nil || container != nil
                ? String(localized: "Unchanged") : String(localized: "Kept in the keychain")
        database.stringValue = db.database ?? ""
        path.stringValue = db.path ?? ""
        name.stringValue = editing?.name ?? (db.name.isEmpty ? "" : db.name)
        nameTyped = editing != nil
        // A database's name is the key for it and for its password. So an edit keeps the name, because a new name
        // would make a copy without the password.
        name.isEditable = editing == nil

        var rows: [(String, NSView)] = []
        if engine.isFile {
            let choose = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(chooseFile))
            let line = NSStackView(views: [path, choose])
            line.spacing = Metrics.gap
            rows.append((String(localized: "File"), line))
        } else {
            let line = NSStackView(views: [host, port])
            line.spacing = Metrics.gap
            rows += [
                (appwrite ? String(localized: "Endpoint") : String(localized: "Host"), appwrite ? host : line),
                (appwrite ? String(localized: "Project ID") : String(localized: "User"), user),
                (appwrite ? String(localized: "API Key") : String(localized: "Password"), password),
                (String(localized: "Database"), database)
            ]
        }
        var parts: [NSView] = [heading, SheetForm.grid(rows)]
        var wide: [NSView] = []
        if let hint = preset?.hint {
            let note = NSTextField(wrappingLabelWithString: hint)
            note.font = .ui(TextSize.caption)
            note.textColor = .secondaryLabelColor
            parts.append(note)
            wide.append(note)
        }
        // Appwrite is a URL whose scheme says SSL, and an SSH tunnel would need a port and break its certificate, so
        // Appwrite gets no SSH or SSL folds.
        if !engine.isFile, !appwrite { parts += folds(db) }
        let separator = NSBox()
        separator.boxType = .separator
        parts.append(separator)

        place.segmentCount = 2
        let project = sheet.app.projectName(sheet.app.worktree(sheet.worktreeId)?.repoId) ?? ""
        place.setLabel(String(localized: "This Project (\(project))"), forSegment: 0)
        place.setLabel(String(localized: "All My Databases"), forSegment: 1)
        place.selectedSegment = inLibrary ? 1 : 0
        place.isEnabled = editing == nil
        place.target = self
        place.action = #selector(changed)
        agents.segmentCount = DatabaseInfo.Access.allCases.count
        for (i, access) in DatabaseInfo.Access.allCases.enumerated() {
            agents.setLabel(DatabaseLook.title(access), forSegment: i)
        }
        let defaultAccess = DatabaseInfo.Access(rawValue: sheet.app.settings[SettingKeys.databaseAccess]) ?? .ask
        agents.selectedSegment = DatabaseInfo.Access.allCases.firstIndex(of: editing?.access ?? defaultAccess) ?? 2
        agents.target = self
        agents.action = #selector(changed)
        stage.target = self
        stage.action = #selector(stageClicked)
        let start = editing?.stage ?? db.stage
        stage.selectedSegment = DatabaseInfo.Stage.allCases.firstIndex(of: start) ?? 0
        let settings = SheetForm.grid([
            (String(localized: "Name"), name), (String(localized: "Keep in"), place),
            (String(localized: "Environment"), stage), ("", why), (String(localized: "Agents"), agents),
            ("", agentsWhy)
        ])
        whyRow = settings.row(at: 3)
        parts.append(settings)

        status.font = .ui(TextSize.caption)
        status.textColor = .secondaryLabelColor
        let back = NSButton(title: String(localized: "Back"), target: self, action: #selector(backed))
        back.isHidden = editing != nil
        add.title = editing == nil ? String(localized: "Add") : String(localized: "Save")
        let buttons = sheet.buttons(back, add, target: self, action: #selector(saved))
        parts += [status, buttons]
        view = SheetForm.stack(parts, wide: wide + [separator, status, buttons], width: DatabaseSheet.width)
        changed()
        check(after: 0)
    }

    /// SSH and SSL, each a checkbox that unfolds its settings. Most databases on this Mac never need them.
    private func folds(_ db: DatabaseInfo) -> [NSView] {
        sshOn.setButtonType(.switch)
        sshOn.title = String(localized: "Through SSH")
        sshOn.state = db.ssh == nil ? .off : .on
        sshOn.target = self
        sshOn.action = #selector(foldsChanged)
        Task { [ssh] in   // reads ~/.ssh/config off the main thread
            ssh.addItems(withObjectValues: await Task.detached { RemoteHost.configHosts() }.value)
        }
        ssh.placeholderString = String(localized: "user@server or a Host from ~/.ssh/config")
        ssh.stringValue = db.ssh ?? ""
        sshRow.setViews([sshOn, ssh], in: .leading)
        sshRow.spacing = Metrics.gapWide
        sslOn.setButtonType(.switch)
        sslOn.title = String(localized: "SSL")
        sslOn.state = db.ssl == nil ? .off : .on
        sslOn.target = self
        sslOn.action = #selector(foldsChanged)
        ssl.addItems(withTitles: [String(localized: "Required"), String(localized: "Off")])
        ssl.selectItem(at: db.ssl == "disable" ? 1 : 0)
        ssl.target = self
        ssl.action = #selector(changed)
        let sslNote = DatabaseSheet.small(String(localized: "Unchecked: when the server offers it"))
        sslRow.setViews([sslOn, ssl, sslNote], in: .leading)
        sslRow.spacing = Metrics.gapWide
        ssh.widthAnchor.constraint(equalToConstant: 260).isActive = true
        foldsChanged()
        return [sshRow, sslRow]
    }

    @objc private func foldsChanged() {
        ssh.isHidden = sshOn.state == .off
        ssl.isHidden = sslOn.state == .off
        sslRow.arrangedSubviews.last?.isHidden = sslOn.state == .on
        changed()
        sheet.fit()
    }

    // MARK: What it says

    /// The database the fields describe, or nil while they don't describe one (no host, no file).
    var typed: DatabaseInfo? {
        var db = editing ?? DatabaseInfo(name: "", engine: engine)
        db.engine = engine
        if engine.isFile {
            let file = (path.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            guard !file.isEmpty else { return nil }
            db.path = file
        } else {
            let server = host.stringValue.trimmingCharacters(in: .whitespaces)
            guard !server.isEmpty else { return nil }
            db.host = server
            db.port = Int(port.stringValue) ?? engine.defaultPort
            db.user = user.stringValue.isEmpty ? nil : user.stringValue
            db.database = database.stringValue.isEmpty ? nil : database.stringValue
            db.ssh = sshOn.state == .on && !ssh.stringValue.isEmpty ? ssh.stringValue : nil
            db.ssl = sslOn.state == .on ? (ssl.indexOfSelectedItem == 1 ? "disable" : "require") : nil
        }
        db.name = name.stringValue.trimmingCharacters(in: .whitespaces)
        db.access = DatabaseInfo.Access.allCases[max(0, agents.selectedSegment)]
        db.set(stage: DatabaseInfo.Stage.allCases[max(0, stage.selectedSegment)])
        return db
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === name { nameTyped = !name.stringValue.isEmpty }
        if !nameTyped { name.stringValue = suggestedName }
        changed()
        check(after: 0.6)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in   // the combo box's text follows the pick only after this call
            guard let self else { return }
            if !self.nameTyped { self.name.stringValue = self.suggestedName }
            self.changed()
            self.check(after: 0)
        }
    }

    private var suggestedName: String {
        if engine.isFile {
            return ((path.stringValue as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return database.stringValue.isEmpty ? host.stringValue : database.stringValue
    }

    /// The environment is only what the user picks, never guessed from the host. The line beside it says what it means.
    @objc private func changed() {
        let db = typed
        let elsewhere = db.map { $0.ssh != nil || $0.host.map { !DatabaseInfo.isLocal($0) } ?? false } ?? false
        let picked = DatabaseInfo.Stage.allCases[max(0, stage.selectedSegment)]
        why.stringValue = Self.why(picked, elsewhere: elsewhere)
        whyRow?.isHidden = why.stringValue.isEmpty   // hides the grid's row, or its gap would stay
        let access = DatabaseInfo.Access.allCases[max(0, agents.selectedSegment)]
        agentsWhy.stringValue =
            picked == .production && access != .hidden && access != .read
            ? String(localized: "Production: agents only read it, whatever is picked here.")
            : DatabaseLook.meaning(access)
        add.isEnabled = db != nil && !(db?.name.isEmpty ?? true)
        place.setEnabled(editing == nil || inLibrary, forSegment: 1)
    }

    @objc private func stageClicked() {
        let free = DatabaseInfo.Access.allCases.firstIndex(of: .free) ?? 3
        if DatabaseInfo.Stage.allCases[max(0, stage.selectedSegment)] == .staging, agents.selectedSegment == free {
            agents.selectedSegment = DatabaseInfo.Access.allCases.firstIndex(of: .ask) ?? 2
        }
        changed()
    }

    /// Says what the environment means for agents. A database that is not on this Mac but is marked Local or
    /// Development gets a word to pick Production if it is one.
    static func why(_ stage: DatabaseInfo.Stage, elsewhere: Bool) -> String {
        let meaning = DatabaseLook.meaning(stage)
        guard stage == .local || stage == .development, elsewhere else { return meaning }
        return String(localized: "Not on this Mac: pick Production if it is one.")
    }

    // MARK: Checking

    /// Connects once typing has paused for `delay`, then says at the form's foot what is there, or why it failed.
    private func check(after delay: TimeInterval) {
        checking?.cancel()
        guard let db = typed else {
            status.stringValue = ""
            return
        }
        let secret = password.stringValue.isEmpty ? nil : password.stringValue
        checking = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }   // typed on, so a newer check runs
            guard let self, !Task.isCancelled else { return }
            self.status.stringValue = String(localized: "Connecting…")
            self.status.textColor = .secondaryLabelColor
            let answer = await self.sheet.app.tryCall(
                DatabaseCheck(worktreeId: self.sheet.worktreeId, database: db, password: secret))
            guard !Task.isCancelled else { return }
            if let found = answer.value {
                let through = db.ssh.map { String(localized: "through \($0) · ") } ?? ""
                self.status.stringValue =
                    through + "\(found.version) · "
                    + String(localized: "\(found.tables) tables") + " · \(found.ms) ms"
                self.status.textColor = .secondaryLabelColor   // it answers: nothing to do, so no colour
                if !found.databases.isEmpty {
                    self.database.removeAllItems()
                    self.database.addItems(withObjectValues: found.databases)
                }
            } else {
                self.status.stringValue = answer.error ?? String(localized: "It doesn’t answer.")
                self.status.textColor = .textRed
            }
            self.sheet.fit()
        }
    }

    // MARK: Buttons

    @objc private func chooseFile() {
        let open = NSOpenPanel()
        open.beginSheetModal(for: sheet.window) { [weak self] response in
            guard response == .OK, let url = open.url, let self else { return }
            self.path.stringValue = url.path
            if !self.nameTyped { self.name.stringValue = self.suggestedName }
            self.changed()
            self.check(after: 0)
        }
    }

    @objc private func saved() {
        guard let db = typed else { return }
        let secret = password.stringValue
        let library = place.selectedSegment == 1
        add.isEnabled = false
        Task {
            let answer = await sheet.app.tryCall(
                DatabaseSave(
                    worktreeId: sheet.worktreeId, database: db,
                    password: secret.isEmpty && (editing != nil || container != nil) ? nil : secret, library: library,
                    container: secret.isEmpty ? container : nil, adding: editing == nil))
            if answer.value != nil {
                sheet.end()
            } else {
                status.stringValue = answer.error ?? ""
                status.textColor = .textRed
                add.isEnabled = true
                sheet.fit()
            }
        }
    }

    @objc private func backed() { sheet.showStart() }
}
