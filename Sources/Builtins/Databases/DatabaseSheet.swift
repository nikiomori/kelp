import AppKit
import Core
import DesignKit
import KelpKit

/// Add Database. It starts with one field that reads whatever is pasted as it's typed (`DatabaseAddress`), and says
/// under it what Kelp understood. Below are the engines to start a new database with, and what this Mac already has.
/// That is other apps' connections, where a click goes to Import, and Docker's running servers, where a click fills
/// the form. Continue, an engine or a container opens the form (`DatabaseForm`) in the same sheet. Editing an existing
/// database opens straight to the form.
@MainActor
final class DatabaseSheet: NSObject, NSTextFieldDelegate {
    static let width: CGFloat = 600
    let app: AppModel, worktreeId: String
    let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.titled], backing: .buffered,
        defer: true)
    private let field = NSTextField()
    private let understood = NSTextField(wrappingLabelWithString: "")
    private let found = NSStackView()
    private let foundTitle = DatabaseSheet.section(String(localized: "Found on This Mac"))
    private let next = NSButton()
    private var parsed: DatabaseAddress?
    private let tiles = NSStackView()
    /// When the line saying Kelp looks for other apps' connections came up, so it stays at least `LoadingView.held`.
    private var lookingSince: Date?
    /// The pane shown after the first one, kept alive while it shows. Read by a test.
    private(set) var pane: AnyObject?

    /// `library` means the database edited is one of All My Projects, so it is saved back there.
    static func run(_ app: AppModel, worktreeId: String, editing: DatabaseInfo?, library: Bool = false) async {
        let sheet = DatabaseSheet(app: app, worktreeId: worktreeId)
        if let editing {
            sheet.openForm(DatabaseAddress(database: editing), editing: editing, library: library)
        } else {
            sheet.showStart()
        }
        _ = await runSheet(sheet.window)
    }

    /// Goes straight to the form, filled in, for a file dropped on the panel or a database duplicated.
    static func run(_ app: AppModel, worktreeId: String, adding address: DatabaseAddress) async {
        let sheet = DatabaseSheet(app: app, worktreeId: worktreeId)
        sheet.openForm(address)
        _ = await runSheet(sheet.window)
    }

    /// Not private: a test builds a pane without running the sheet.
    init(app: AppModel, worktreeId: String) {
        self.app = app
        self.worktreeId = worktreeId
        super.init()
    }

    func end() { window.sheetParent?.endSheet(window, returnCode: .OK) }

    func show(_ view: NSView, first: NSView?) {
        window.contentView = view
        fit()
        window.initialFirstResponder = first
        window.makeFirstResponder(first)
    }

    /// Sizes the sheet as tall as what it shows (`SheetForm.fit`): each pane is a `SheetForm.stack`.
    func fit() { SheetForm.fit(window) }

    // MARK: The first pane

    func showStart() {
        pane = nil
        let title = NSTextField(labelWithString: String(localized: "Add Database"))
        title.font = .ui(TextSize.body, weight: .semibold)
        let project = app.projectName(app.worktree(worktreeId)?.repoId) ?? String(localized: "this project")
        let lead = Self.small(
            String(localized: "Databases in \(project)’s files are listed already. Add any other here."))
        let heading = NSStackView(views: [Self.mark(), Self.column([title, lead], spacing: Metrics.lineGap)])
        heading.spacing = Metrics.gapWide
        heading.alignment = .centerY

        field.placeholderString = String(localized: "Search, or paste a connection URL or a file’s path")
        field.font = .ui(TextSize.body)
        field.delegate = self
        field.controlSize = .large
        understood.font = .ui(TextSize.caption)
        understood.isHidden = true

        tiles.orientation = .vertical
        tiles.alignment = .leading
        tiles.spacing = 2
        layTiles("")
        let ask = ClosureButton(title: String(localized: "Ask for One")) {
            if let url = URL(string: "https://github.com/nikiomori/kelp/issues/new") { PreviewLinks.openOutside(url) }
        }
        ask.bezelStyle = .push
        ask.controlSize = .small
        let later = NSStackView(
            views: [Self.small(String(localized: "Not yet: SQL Server, ClickHouse, MongoDB, Redis, Oracle.")), ask])
        later.spacing = Metrics.gapWide

        found.arrangedSubviews.forEach { $0.removeFromSuperview() }   // Back comes here again: read afresh
        found.orientation = .vertical
        found.alignment = .leading
        found.spacing = 0
        foundTitle.isHidden = true   // until a row comes, or the reads take long enough to say they look
        let file = ClosureButton(title: String(localized: "Import from File…")) { [weak self] in self?.importFile() }
        file.bezelStyle = .push
        next.title = String(localized: "Continue")
        next.isEnabled = false
        let buttons = buttons(file, next, target: self, action: #selector(continued))
        show(
            SheetForm.stack(
                [heading, field, understood, tiles, later, foundTitle, found, buttons],
                wide: [field, understood, found, buttons], width: Self.width), first: field)
        Task { await fillFound() }
    }

    /// Adds other apps' connections, then Docker's running servers, as rows that come in as they're read. They are
    /// this Mac's own files and daemon, so the line that says it looks shows only past a second (`whileSlow`), and
    /// then stays at least `LoadingView.held`.
    private func fillFound() async {
        let spinner = NSProgressIndicator.small()
        spinner.startAnimation(nil)
        let words = Self.small(String(localized: "Looking for other apps’ connections…"))
        let looking = NSStackView(views: [spinner, words])
        looking.spacing = Metrics.gap
        looking.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: 0, bottom: Metrics.gap, right: 0)
        lookingSince = nil
        let slow = whileSlow { [weak self] in
            guard let self else { return }
            lookingSince = .now
            found.addArrangedSubview(looking)
            foundTitle.isHidden = false
            looking.fadeIn()
            if pane == nil { fit() }
        }
        let sources = await app.quiet(DatabaseImportSources()) ?? []
        for source in sources where source.count > 0 {
            let engines = source.engines.map(\.displayName).joined(separator: ", ")
            add(
                FoundRow(
                    icon: DatabaseLook.appIcon(source.id), title: source.name,
                    detail: String(localized: "\(source.count) connections · \(engines)"), trailing: nil
                ) { [weak self] in self?.openImport(source, file: nil) }, above: looking)
        }
        let running = await app.quiet(DatabaseContainers()) ?? []
        for server in running {
            let port = server.database.port.map(String.init) ?? ""
            add(
                FoundRow(
                    icon: .symbol("shippingbox"), title: server.name,
                    detail: "\(server.image) · \(String(localized: "port")) \(port)", trailing: String(localized: "Use")
                ) { [weak self] in
                    self?.openForm(DatabaseAddress(database: server.database), container: server.container)
                }, above: looking)
        }
        slow.cancel()
        if let since = lookingSince {
            let left = LoadingView.held - Date.now.timeIntervalSince(since)
            if left > 0 {
                do { try await Task.sleep(for: .seconds(left)) } catch { return }
            }
        }
        looking.removeFromSuperview()
        foundTitle.isHidden = found.arrangedSubviews.isEmpty
        if pane == nil { fit() }
    }

    private func add(_ row: FoundRow, above looking: NSView) {
        row.isHidden = true
        let end = found.arrangedSubviews.count
        found.insertArrangedSubview(row, at: found.arrangedSubviews.firstIndex(of: looking) ?? end)
        row.widthAnchor.constraint(equalTo: found.widthAnchor).isActive = true
        foundTitle.isHidden = false
        row.fadeIn()
        if pane == nil { fit() }
    }

    func controlTextDidChange(_ notification: Notification) { read() }

    /// Return in the field means Continue, because the field editor takes Return before the default button would.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), parsed != nil else { return false }
        continued()
        return true
    }

    /// Says under the field how Kelp reads it: the database and where it is, or what Kelp can't read.
    private func read() {
        let text = field.stringValue
        do {
            let address = try DatabaseAddress.parse(text)
            parsed = address
            understood.attributedStringValue = Self.understood(address.database, password: address.password != nil)
        } catch {
            parsed = nil
            understood.stringValue = text.trimmingCharacters(in: .whitespaces).isEmpty ? "" : error.message
            understood.textColor = .secondaryLabelColor
        }
        understood.isHidden = understood.stringValue.isEmpty
        next.isEnabled = parsed != nil
        found.alphaValue = parsed == nil ? 1 : 0.45
        // When the text is not an address, its words find an engine or a service in the grid.
        layTiles(parsed == nil ? text.trimmingCharacters(in: .whitespaces) : "")
        if parsed == nil, !text.contains(":"), !text.contains("/") { understood.isHidden = true }
        fit()
    }

    /// What Kelp understood: "Postgres · app_staging" over "app on db.example.com:5432 · SSL required", and where the
    /// password goes.
    static func understood(_ db: DatabaseInfo, password: Bool) -> NSAttributedString {
        let place =
            db.engine.isFile
            ? db.path ?? ""
            : "\(db.user.map { $0 + " " + String(localized: "on") + " " } ?? "")\(db.host ?? ""):\(db.port ?? 0)"
        let ssl =
            db.ssl == "require"
            ? " · " + String(localized: "SSL required")
            : db.ssl?.hasPrefix("verify") == true ? " · " + String(localized: "SSL, certificate checked") : ""
        let key =
            db.engine.isFile
            ? ""
            : password
                ? String(localized: "The password goes to the keychain.")
                : String(localized: "No password in it: the next step asks.")
        let text = NSMutableAttributedString(
            string: "\(db.engine.displayName) · \(db.database ?? db.name)\n",
            attributes: [.font: NSFont.ui(TextSize.row, weight: .medium), .foregroundColor: NSColor.labelColor])
        text.append(
            NSAttributedString(
                string: place + ssl + (key.isEmpty ? "" : "\n" + key),
                attributes: [.font: NSFont.ui(TextSize.caption), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    /// Lays out the presets whose name contains `find`, six to a row.
    private func layTiles(_ find: String) {
        for row in tiles.arrangedSubviews { row.removeFromSuperview() }
        let shown = EnginePreset.all.filter { find.isEmpty || $0.name.lowercased().contains(find.lowercased()) }
        stride(from: 0, to: shown.count, by: 6).forEach { start in
            let row = NSStackView(
                views: shown[start..<min(start + 6, shown.count)].map { preset in
                    EngineTile(preset) { [weak self] in self?.newOne(preset) }
                })
            row.spacing = 4
            tiles.addArrangedSubview(row)
        }
    }

    func newOne(_ preset: EnginePreset) {
        var db = DatabaseInfo(
            name: "", engine: preset.engine, host: preset.engine.isFile ? nil : "localhost",
            port: preset.port ?? preset.engine.defaultPort)
        db.ssl = preset.ssl
        if preset.speaks != nil || preset.engine == .appwrite, !preset.engine.isFile { db.host = "" }   // has own host
        openForm(DatabaseAddress(database: db), preset: preset)
    }

    @objc private func continued() {
        guard let parsed else { return }
        openForm(parsed)
    }

    @objc private func importFile() {
        let open = NSOpenPanel()
        open.message = String(localized: "pgAdmin’s servers.json, or Navicat’s .ncx")
        open.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            let navicat = url.pathExtension.lowercased() == "ncx"
            let source = ImportSource(
                id: navicat ? "navicat" : "pgadmin", name: url.lastPathComponent, count: 0, engines: [],
                passwords: navicat ? "file" : "none")
            self?.openImport(source, file: url.path)
        }
    }

    @objc private func cancelled() { window.sheetParent?.endSheet(window, returnCode: .cancel) }

    /// A pane's bottom row: `leading` at the left, then Cancel (Escape), which ends the sheet, and `primary` (Return),
    /// sending `action` to `target`.
    func buttons(_ leading: NSView, _ primary: NSButton, target: AnyObject, action: Selector) -> NSStackView {
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        primary.bezelStyle = .push
        primary.keyEquivalent = "\r"
        primary.target = target
        primary.action = action
        let row = NSStackView(views: [leading, NSView(), cancel, primary])
        row.spacing = Metrics.gapWide
        return row
    }

    // MARK: Other panes

    func openForm(
        _ address: DatabaseAddress, editing: DatabaseInfo? = nil, container: String? = nil, preset: EnginePreset? = nil,
        library: Bool = false
    ) {
        let form = DatabaseForm(
            sheet: self, address: address, editing: editing, container: container, preset: preset, library: library)
        pane = form
        show(form.view, first: form.firstField)
    }

    func openImport(_ source: ImportSource, file: String?) {
        let importing = DatabaseImportPane(sheet: self, source: source, file: file)
        pane = importing
        show(importing.view, first: nil)
    }

    // MARK: Parts

    static func mark() -> NSImageView {
        let mark = NSImageView(image: .symbol(DatabaseLook.symbol))
        mark.symbolConfiguration = .chrome(Metrics.iconMenu)
        mark.contentTintColor = .secondaryLabelColor
        return mark
    }

    /// A section's title, as every section's: 11 semibold, secondary.
    static func section(_ title: String) -> NSTextField {
        .label(title, font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
    }

    static func small(_ text: String) -> NSTextField {
        .label(text, font: .ui(TextSize.caption), color: .secondaryLabelColor)
    }

    static func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }
}

/// A row of "Found on This Mac": the app's own icon (or a symbol), a name over a detail, and an action on click.
@MainActor
final class FoundRow: PointerControl {
    init(icon: NSImage, title: String, detail: String, trailing: String?, action: @escaping () -> Void) {
        super.init(frame: .zero)
        onClick = action
        layer?.cornerRadius = Metrics.radiusSM
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        let side = Metrics.iconMenu + 4
        image.widthAnchor.constraint(equalToConstant: side).isActive = true
        image.heightAnchor.constraint(equalToConstant: side).isActive = true
        let name = NSTextField(labelWithString: title)
        name.font = .ui(TextSize.body)
        let under = DatabaseSheet.small(detail)
        let end: NSView
        if let trailing {
            end = DatabaseSheet.small(trailing)
        } else {
            let chevron = NSImageView(image: .symbol("chevron.right"))
            chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
            chevron.contentTintColor = .tertiaryLabelColor
            end = chevron
        }
        let stack = NSStackView(
            views: [image, DatabaseSheet.column([name, under], spacing: Metrics.lineGap), NSView(), end])
        stack.spacing = Metrics.gapWide
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gap, bottom: 0, right: Metrics.gapWide)
        pin(stack)
        heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.rowTwoLine)).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }
}
