import AppKit
import Core
import DesignKit
import KelpKit

/// Import Connections, in Add Database's sheet: one app's connections with a checkbox each (one Kelp has already is
/// off and says so), each with why it's Production or what SSH needs. Under them, whether to take the passwords too
/// (said as the app keeps them: macOS asks for each, or Kelp reads its file) and whether this project's agents may
/// use them now. They land in All my projects.
@MainActor
final class DatabaseImportPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let sheet: DatabaseSheet
    private let source: ImportSource, file: String?
    private let table = NSTableView()
    private let passwords = NSButton(), useHere = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let go = NSButton()
    private var rows: [ImportedDatabase] = []
    private var chosen = Set<String>()
    private(set) var view = NSView()

    init(sheet: DatabaseSheet, source: ImportSource, file: String?) {
        self.sheet = sheet
        self.source = source
        self.file = file
        super.init()
        build()
        Task { await load() }
    }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "Import from \(source.name)"))
        title.font = .ui(13, weight: .semibold)
        let icon = NSImageView(image: DatabaseLook.appIcon(source.id))
        icon.widthAnchor.constraint(equalToConstant: Metrics.iconMenu + 4).isActive = true
        icon.heightAnchor.constraint(equalToConstant: Metrics.iconMenu + 4).isActive = true
        let heading = NSStackView(views: [icon, title])
        heading.spacing = Metrics.gapWide

        let column = NSTableColumn(identifier: .init("db"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Metrics.rowTwoLine + 4
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true

        passwords.setButtonType(.switch)
        passwords.state = source.passwords == "none" ? .off : .on
        passwords.isEnabled = source.passwords != "none"
        passwords.title =
            switch source.passwords {
            case "keychain": String(localized: "Take the passwords from the keychain: macOS asks for each one")
            case "file": String(localized: "Take the passwords: Kelp reads them from \(source.name)’s files")
            default: String(localized: "\(source.name) keeps no passwords Kelp can read: each is asked when first used")
            }
        let project = sheet.app.projectName(sheet.app.worktree(sheet.worktreeId)?.repoId) ?? ""
        useHere.setButtonType(.switch)
        useHere.title = String(localized: "Let \(project)’s agents use them now (others read only)")
        useHere.state = .off
        status.font = .ui(11)
        status.textColor = .secondaryLabelColor
        status.stringValue = String(localized: "Reading…")

        let back = NSButton(title: String(localized: "Back"), target: self, action: #selector(backed))
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        go.bezelStyle = .push
        go.keyEquivalent = "\r"
        go.target = self
        go.action = #selector(imported)
        let buttons = NSStackView(views: [back, NSView(), cancel, go])
        buttons.spacing = Metrics.gapWide
        view = SheetForm.stack(
            [heading, scroll, passwords, useHere, status, buttons], wide: [scroll, status, buttons],
            width: DatabaseSheet.width)
        update()
    }

    private func load() async {
        let answer = await sheet.app.tryCall(
            DatabaseImportRead(worktreeId: sheet.worktreeId, source: source.id, file: file))
        rows = answer.value ?? []
        chosen = Set(rows.filter { !$0.known }.map(\.id))
        status.stringValue =
            answer.error
            ?? (rows.isEmpty
                ? String(localized: "Nothing Kelp can open in it: Postgres, MySQL, SQLite and DuckDB.")
                : String(
                    localized:
                        "They go to All My Projects, where you open them; agents see one once it’s used in a project."))
        table.reloadData()
        update()
    }

    private func update() {
        go.title = String(localized: "Import \(chosen.count)")
        go.isEnabled = !chosen.isEmpty
    }

    // MARK: List

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row], db = item.database
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        check.tag = row
        check.state = chosen.contains(item.id) ? .on : .off
        let name = NSTextField(labelWithString: db.name)
        name.font = .ui(13)
        name.lineBreakMode = .byTruncatingTail
        let place = db.engine.isFile ? db.path ?? "" : "\(db.host ?? ""):\(db.port.map(String.init) ?? "")"
        let parts = [DatabaseLook.engine(db.engine), place, db.group].compactMap { $0 }
        let detail = DatabaseSheet.small(
            item.known
                ? String(localized: "Kelp has it already")
                : (parts + [item.note].compactMap { $0 }).joined(separator: " · "))
        detail.lineBreakMode = .byTruncatingTail
        let words = DatabaseSheet.column([name, detail], spacing: Metrics.lineGap)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [check, NSImageView(image: DatabaseLook.badge(db.engine, size: 16)), words, NSView()]
        if db.production { views.append(DatabaseLook.productionChip()) }
        let line = NSStackView(views: views)
        line.spacing = Metrics.gapWide
        line.alignment = .centerY
        line.alphaValue = item.known ? 0.5 : 1
        line.toolTip = item.note
        return line
    }

    @objc private func toggled(_ sender: NSButton) {
        let id = rows[sender.tag].id
        if sender.state == .on { chosen.insert(id) } else { chosen.remove(id) }
        update()
    }

    // MARK: Buttons

    @objc private func imported() {
        go.isEnabled = false
        status.stringValue =
            passwords.state == .on && source.passwords == "keychain"
            ? String(localized: "macOS asks whether Kelp may read each password: Always Allow saves asking again.")
            : String(localized: "Importing…")
        Task {
            let answer = await sheet.app.tryCall(
                DatabaseImport(
                    worktreeId: sheet.worktreeId, source: source.id, file: file,
                    ids: rows.map(\.id).filter(chosen.contains),
                    passwords: passwords.state == .on, useHere: useHere.state == .on))
            if answer.value != nil {
                sheet.end()
            } else {
                status.stringValue = answer.error ?? ""
                status.textColor = .systemRed
                update()
            }
        }
    }

    @objc private func backed() { sheet.showStart() }
    @objc private func cancelled() { sheet.window.sheetParent?.endSheet(sheet.window, returnCode: .cancel) }
}
