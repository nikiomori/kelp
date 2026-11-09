import AppKit
import Core
import DesignKit
import KelpKit

/// The form of Add Database: only the engine's own fields (a file's path; or host, port, user, password, database),
/// SSH and SSL folded until they're wanted, then its name, where it's kept, what agents may do, Production and why. It
/// connects by itself once typing pauses (`db.check`): the line at its foot says what's there, or the server's words.
/// Add works without a check that passed: a server may be down for now.
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
    private let place = NSSegmentedControl(), agents = NSSegmentedControl()
    private let stage = NSSegmentedControl(
        labels: DatabaseInfo.Stage.allCases.map(DatabaseLook.title), trackingMode: .selectOne, target: nil, action: nil)
    private let why = DatabaseSheet.small("")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let add = NSButton()
    private var nameTyped = false, productionTouched = false
    private var checking: Task<Void, Never>?
    private(set) var view = NSView()
    /// A new one starts at its host (or file); one pasted, picked or edited at its password.
    var firstField: NSView { engine.isFile ? path : fresh ? host : password }
    private let fresh: Bool

    private let preset: EnginePreset?
    private var whyRow: NSGridRow?

    init(
        sheet: DatabaseSheet, address: DatabaseAddress, editing: DatabaseInfo?, container: String?,
        preset: EnginePreset? = nil
    ) {
        self.sheet = sheet
        self.preset = preset
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
        let title = NSTextField(labelWithString: editing?.name ?? preset?.name ?? DatabaseLook.engine(engine))
        title.font = .ui(13, weight: .semibold)
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
        port.placeholderString = engine == .postgres ? "5432" : "3306"
        port.widthAnchor.constraint(equalToConstant: 64).isActive = true
        user.stringValue = db.user ?? ""
        user.placeholderString = engine == .postgres ? NSUserName() : "root"
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
                (String(localized: "Host"), line), (String(localized: "User"), user),
                (String(localized: "Password"), password), (String(localized: "Database"), database)
            ]
        }
        var parts: [NSView] = [heading, SheetForm.grid(rows)]
        if let hint = preset?.hint {
            let note = DatabaseSheet.small(hint)
            note.lineBreakMode = .byWordWrapping
            parts.append(note)
        }
        if !engine.isFile { parts += folds(db) }
        let separator = NSBox()
        separator.boxType = .separator
        parts.append(separator)

        place.segmentCount = 2
        let project = sheet.app.projectName(sheet.app.worktree(sheet.worktreeId)?.repoId) ?? ""
        place.setLabel(String(localized: "This Project (\(project))"), forSegment: 0)
        place.setLabel(String(localized: "All My Projects"), forSegment: 1)
        place.selectedSegment = 0
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
        productionTouched = editing != nil || db.environment != nil
        let settings = SheetForm.grid([
            (String(localized: "Name"), name), (String(localized: "Keep in"), place),
            (String(localized: "Environment"), stage), ("", why), (String(localized: "Agents"), agents)
        ])
        whyRow = settings.row(at: 3)
        parts.append(settings)

        status.font = .ui(11)
        status.textColor = .secondaryLabelColor
        let back = NSButton(title: String(localized: "Back"), target: self, action: #selector(backed))
        back.isHidden = editing != nil
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        add.title = editing == nil ? String(localized: "Add") : String(localized: "Save")
        add.bezelStyle = .push
        add.keyEquivalent = "\r"
        add.target = self
        add.action = #selector(saved)
        let buttons = NSStackView(views: [back, NSView(), cancel, add])
        buttons.spacing = Metrics.gapWide
        parts += [status, buttons]
        view = SheetForm.stack(parts, wide: [separator, status, buttons], width: DatabaseSheet.width)
        changed()
        check(after: 0)
    }

    /// SSH and SSL, each a checkbox that unfolds its choice: what most databases on this Mac never need.
    private func folds(_ db: DatabaseInfo) -> [NSView] {
        sshOn.setButtonType(.switch)
        sshOn.title = String(localized: "Through SSH")
        sshOn.state = db.ssh == nil ? .off : .on
        sshOn.target = self
        sshOn.action = #selector(foldsChanged)
        ssh.addItems(withObjectValues: DatabaseForm.sshHosts())
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

    /// The database the fields describe; nil while they don't (no host, no file).
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
            db.port = Int(port.stringValue) ?? (engine == .postgres ? 5432 : 3306)
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

    func controlTextDidChange(_ n: Notification) {
        if n.object as? NSTextField === name { nameTyped = !name.stringValue.isEmpty }
        if !nameTyped { name.stringValue = suggestedName }
        changed()
        check(after: 0.6)
    }

    func comboBoxSelectionDidChange(_ n: Notification) {
        DispatchQueue.main.async { [weak self] in   // the combo box's text follows the pick after this call
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

    /// Production follows where it is until the user sets it; the line beside it says why.
    @objc private func changed() {
        let db = typed
        let elsewhere = db.map { $0.ssh != nil || $0.host.map { !Self.onThisMac($0) } ?? false } ?? false
        if !productionTouched {
            stage.selectedSegment = DatabaseInfo.Stage.allCases.firstIndex(of: elsewhere ? .production : .local) ?? 0
        }
        let picked = DatabaseInfo.Stage.allCases[max(0, stage.selectedSegment)]
        why.stringValue = Self.why(picked, elsewhere: elsewhere)
        whyRow?.isHidden = why.stringValue.isEmpty   // the grid's row, or its gap stays
        add.isEnabled = db != nil && !(db?.name.isEmpty ?? true)
        place.setEnabled(editing == nil, forSegment: 1)
    }

    @objc private func stageClicked() {
        productionTouched = true
        let free = DatabaseInfo.Access.allCases.firstIndex(of: .free) ?? 3
        if DatabaseInfo.Stage.allCases[max(0, stage.selectedSegment)] == .staging, agents.selectedSegment == free {
            agents.selectedSegment = DatabaseInfo.Access.allCases.firstIndex(of: .ask) ?? 2
        }
        changed()
    }

    /// What the environment means for agents, and a word when one elsewhere isn't Production.
    static func why(_ stage: DatabaseInfo.Stage, elsewhere: Bool) -> String {
        switch stage {
        case .production:
            return elsewhere
                ? String(localized: "Not on this Mac: agents only read it.") : String(localized: "Agents only read it.")
        case .staging: return String(localized: "Agents ask before each change, at most.")
        default: return elsewhere ? String(localized: "Not on this Mac: is it a copy you may break?") : ""
        }
    }

    static func onThisMac(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "0.0.0.0", "host.docker.internal"].contains(host.lowercased())
    }

    // MARK: Checking

    /// Connects once typing has paused for `delay`: what's there, or why not, at the form's foot.
    private func check(after delay: TimeInterval) {
        checking?.cancel()
        guard let db = typed else {
            status.stringValue = ""
            return
        }
        let secret = password.stringValue.isEmpty ? nil : password.stringValue
        checking = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }   // typed on: a newer check
            guard let self, !Task.isCancelled else { return }
            self.status.stringValue = String(localized: "Connecting…")
            self.status.textColor = .secondaryLabelColor
            let answer = await self.sheet.app.tryCall(
                DatabaseCheck(worktreeId: self.sheet.worktreeId, database: db, password: secret))
            guard !Task.isCancelled else { return }
            if let found = answer.value {
                let through = db.ssh.map { String(localized: "through \($0) · ") } ?? ""
                self.status.stringValue =
                    "● " + through + "\(found.version) · "
                    + String(localized: "\(found.tables) tables") + " · \(found.ms) ms"
                self.status.textColor = .systemGreen
                if !found.databases.isEmpty {
                    self.database.removeAllItems()
                    self.database.addItems(withObjectValues: found.databases)
                }
            } else {
                self.status.stringValue = "● " + (answer.error ?? String(localized: "It doesn’t answer."))
                self.status.textColor = .systemOrange
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
                    container: secret.isEmpty ? container : nil))
            if answer.value != nil {
                sheet.end()
            } else {
                status.stringValue = "● " + (answer.error ?? "")
                status.textColor = .systemRed
                add.isEnabled = true
                sheet.fit()
            }
        }
    }

    @objc private func backed() { sheet.showStart() }
    @objc private func cancelled() { sheet.window.sheetParent?.endSheet(sheet.window, returnCode: .cancel) }

    /// The `Host` names in ~/.ssh/config (patterns left out).
    static func sshHosts() -> [String] {
        let text: String
        do { text = try String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8) } catch {
            return []
        }
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.first?.lowercased() == "host" else { return [] }
            return words.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        }
    }
}
