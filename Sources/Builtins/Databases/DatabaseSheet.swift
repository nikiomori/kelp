import AppKit
import Core
import DesignKit
import KelpKit

/// Add Database. One field first: whatever is pasted is read as it's typed (`DatabaseAddress`) and what Kelp understood
/// is said under it. Under that, a new one by engine, and what this Mac has already: other apps' connections (a click
/// goes to Import) and Docker's running servers (a click fills the form). Continue, an engine or a container goes to the
/// form (`DatabaseForm`), in the same sheet; an existing database opens straight there.
@MainActor
final class DatabaseSheet: NSObject, NSTextFieldDelegate {
    static let width: CGFloat = 520
    /// The order the engines are offered in: servers first, the most used first.
    static let engines: [DatabaseInfo.Engine] = [.postgres, .mysql, .sqlite, .duckdb]
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
    /// The pane on screen past the first: kept while it shows.
    private var pane: AnyObject?

    static func run(_ app: AppModel, worktreeId: String, editing: DatabaseInfo?) async {
        let sheet = DatabaseSheet(app: app, worktreeId: worktreeId)
        if let editing {
            sheet.openForm(DatabaseAddress(database: editing), editing: editing)
        } else {
            sheet.showStart()
        }
        _ = await runSheet(sheet.window)
    }

    private init(app: AppModel, worktreeId: String) {
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

    /// As tall as what it shows, always the sheet's width (fittingSize alone comes out narrower).
    func fit() {
        window.setContentSize(NSSize(width: Self.width, height: window.contentView?.fittingSize.height ?? 0))
    }

    // MARK: The first pane

    func showStart() {
        pane = nil
        let title = NSTextField(labelWithString: String(localized: "Add Database"))
        title.font = .ui(13, weight: .semibold)
        let project = app.projectName(app.worktree(worktreeId)?.repoId) ?? String(localized: "this project")
        let lead = Self.small(
            String(localized: "Databases in \(project)’s files are listed already. Add any other here."))
        let heading = NSStackView(views: [Self.mark(), Self.column([title, lead], spacing: Metrics.lineGap)])
        heading.spacing = Metrics.gapWide
        heading.alignment = .centerY

        field.placeholderString = String(localized: "Paste a connection URL, or a database file’s path")
        field.font = .ui(13)
        field.delegate = self
        field.controlSize = .large
        understood.font = .ui(11)
        understood.isHidden = true

        let engines = NSStackView(views: [Self.small(String(localized: "Or start a new one:"))])
        engines.spacing = Metrics.gap
        for (index, engine) in Self.engines.enumerated() {
            let button = NSButton(
                title: DatabaseLook.engine(engine), image: DatabaseLook.badge(engine), target: self,
                action: #selector(newOne(_:)))
            button.imagePosition = .imageLeading
            button.controlSize = .small
            button.bezelStyle = .push
            button.tag = index
            engines.addArrangedSubview(button)
        }

        found.orientation = .vertical
        found.alignment = .leading
        found.spacing = 0
        foundTitle.isHidden = true
        let file = NSButton(title: String(localized: "Import from File…"), target: self, action: #selector(importFile))
        file.isBordered = false
        file.contentTintColor = .linkColor
        file.font = .ui(12)
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        next.title = String(localized: "Continue")
        next.bezelStyle = .push
        next.keyEquivalent = "\r"
        next.target = self
        next.action = #selector(continued)
        next.isEnabled = false
        let buttons = NSStackView(views: [file, NSView(), cancel, next])
        buttons.spacing = Metrics.gapWide
        show(
            SheetForm.stack(
                [heading, field, understood, engines, foundTitle, found, buttons],
                wide: [field, understood, found, buttons], width: Self.width), first: field)
        Task { await fillFound() }
    }

    /// Other apps' connections, then Docker's running servers: rows that come in as they're read.
    private func fillFound() async {
        let sources = await app.quiet(DatabaseImportSources()) ?? []
        for source in sources where source.count > 0 {
            let engines = source.engines.map(DatabaseLook.engine).joined(separator: ", ")
            add(
                FoundRow(
                    icon: DatabaseLook.appIcon(source.id), title: source.name,
                    detail: String(localized: "\(source.count) connections · \(engines)"), trailing: nil
                ) { [weak self] in self?.openImport(source, file: nil) })
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
                })
        }
        foundTitle.isHidden = found.arrangedSubviews.isEmpty
        if pane == nil { fit() }
    }

    private func add(_ row: FoundRow) {
        found.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: found.widthAnchor).isActive = true
    }

    func controlTextDidChange(_ n: Notification) { read() }

    /// Return in the field is Continue: the field editor takes it before the default button would.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), parsed != nil else { return false }
        continued()
        return true
    }

    /// What the field says, as Kelp reads it: the database and where, or what it can't read.
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
        fit()
    }

    /// "Postgres · app_staging" over "app on db.example.com:5432 · SSL required" and where the password goes.
    static func understood(_ db: DatabaseInfo, password: Bool) -> NSAttributedString {
        let place =
            db.engine.isFile
            ? db.path ?? ""
            : "\(db.user.map { $0 + " " + String(localized: "on") + " " } ?? "")\(db.host ?? ""):\(db.port ?? 0)"
        let ssl = db.ssl == "require" ? " · " + String(localized: "SSL required") : ""
        let key =
            db.engine.isFile
            ? ""
            : password
                ? String(localized: "The password goes to the keychain.")
                : String(localized: "No password in it: the next step asks.")
        let text = NSMutableAttributedString(
            string: "\(DatabaseLook.engine(db.engine)) · \(db.database ?? db.name)\n",
            attributes: [.font: NSFont.ui(12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        text.append(
            NSAttributedString(
                string: place + ssl + (key.isEmpty ? "" : "\n" + key),
                attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    @objc private func newOne(_ sender: NSButton) {
        let engine = Self.engines[sender.tag]
        let port = engine == .postgres ? 5432 : engine == .mysql ? 3306 : nil
        let db = DatabaseInfo(name: "", engine: engine, host: engine.isFile ? nil : "localhost", port: port)
        openForm(DatabaseAddress(database: db))
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

    // MARK: Other panes

    func openForm(_ address: DatabaseAddress, editing: DatabaseInfo? = nil, container: String? = nil) {
        let form = DatabaseForm(sheet: self, address: address, editing: editing, container: container)
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
        mark.symbolConfiguration = .init(pointSize: Metrics.iconMenu, weight: .regular)
        mark.contentTintColor = .secondaryLabelColor
        return mark
    }

    static func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .ui(11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    static func small(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .ui(11)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }
}

/// A row of "Found on This Mac": the app's own icon (or a symbol), a name over a detail, and a click.
@MainActor
final class FoundRow: NSView {
    private let action: () -> Void
    private var hover = false {
        didSet { needsDisplay = true }
    }

    init(icon: NSImage, title: String, detail: String, trailing: String?, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        let side = Metrics.iconMenu + 4
        image.widthAnchor.constraint(equalToConstant: side).isActive = true
        image.heightAnchor.constraint(equalToConstant: side).isActive = true
        let name = NSTextField(labelWithString: title)
        name.font = .ui(13)
        let under = DatabaseSheet.small(detail)
        under.lineBreakMode = .byTruncatingTail
        let end: NSView
        if let trailing {
            end = DatabaseSheet.small(trailing)
        } else {
            let chevron = NSImageView(image: .symbol("chevron.right"))
            chevron.contentTintColor = .tertiaryLabelColor
            end = chevron
        }
        let stack = NSStackView(
            views: [image, DatabaseSheet.column([name, under], spacing: Metrics.lineGap), NSView(), end])
        stack.spacing = Metrics.gapWide
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gap, bottom: 0, right: Metrics.gapWide)
        pin(stack)
        heightAnchor.constraint(equalToConstant: Metrics.rowTwoLine + 4).isActive = true
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hover else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusSM, yRadius: Metrics.radiusSM).fill()
    }
}
