import AppKit
import Core
import DesignKit

/// What the run chip opens: everything the project offers to run, by the file it comes from, what last ran marked ⌘R,
/// what runs now with its page and a stop. A click (or ↑ ↓ and Return) runs one and makes it the project's ⌘R;
/// installing dependencies is a section of its own and never becomes ⌘R.
@MainActor
final class RunPicker: NSViewController {
    struct Row: Equatable {
        var id: String, name: String, command: String
        /// The program it needs that isn't installed.
        var missing: String?
        /// Running now: its session, and the page it serves.
        var session: String?, url: String?
        var key: String?
    }
    struct Section: Equatable { var title: String; var rows: [Row] }

    private static let width: CGFloat = 320
    private let app: AppModel
    private let wid: String
    private let list = NSStackView()
    private var rows: [PickRow] = []
    private var selected = 0 { didSet { showSelection() } }

    init(app: AppModel, workspace: String) {
        self.app = app
        wid = workspace
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Run"))
        title.font = .ui(15, weight: .semibold)
        let edit = PointerButton(title: String(localized: "Edit Commands…")) { [weak self] in
            self?.view.window?.close()
            self?.app.scripts.edit()
        }
        edit.font = .ui(12)
        edit.contentTintColor = .secondaryLabelColor
        edit.padding = 4
        edit.isBordered = false
        let head = NSStackView(views: [title, NSView(), edit])
        let w = app.worktree(wid)
        let place = w.map { w in RemoteHost.of(w.path).map { String(localized: "\(w.displayName) on \($0.host)") }
            ?? "\(w.displayName) · \((w.path as NSString).abbreviatingWithTildeInPath)" } ?? ""
        let whereLabel = label(place, size: 12)
        whereLabel.lineBreakMode = .byTruncatingMiddle
        let hint = label(String(localized: "⌘R runs the marked one · ⌃⌘R opens this list"), size: 11)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 1
        let root = KeyStack(views: [head, whereLabel, list, hint])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.setCustomSpacing(2, after: head)
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.onKey = { [weak self] in self?.key($0) ?? false }
        for v in [head, list] { v.widthAnchor.constraint(equalToConstant: Self.width - 24).isActive = true }
        view = root
        let app = self.app, wid = self.wid
        track(owner: self) { app.scripts.sections(wid) } changed: { [weak self] in self?.show($0) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    private func show(_ sections: [Section]) {
        rows = []
        var views: [NSView] = []
        for s in sections {
            let caption = label(s.title, size: 11)
            caption.font = .ui(11, weight: .semibold)
            views.append(caption)
            for r in s.rows {
                let row = PickRow(r) { [weak self] in self?.pick(r) }
                row.onStop = { [weak self] in self?.stop(r) }
                row.onPage = { [weak self] in self?.page(r) }
                row.widthAnchor.constraint(equalToConstant: Self.width - 24).isActive = true
                rows.append(row)
                views.append(row)
            }
        }
        if sections.isEmpty {
            let none = label(String(localized: "Nothing to run found. Kelp reads package.json, Makefile, compose.yaml, pyproject.toml, Cargo.toml, go.mod and more; add your own in .kelp.yaml."), size: 12)
            none.preferredMaxLayoutWidth = Self.width - 24
            views.append(none)
        }
        list.setViews(views, in: .top)
        selected = rows.firstIndex { $0.row.key != nil } ?? 0
    }

    private func showSelection() { for (i, r) in rows.enumerated() { r.restFill = i == selected ? .fillSelected : nil } }

    private func key(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 125: selected = min(selected + 1, rows.count - 1)
        case 126: selected = max(selected - 1, 0)
        case 36, 76: if rows.indices.contains(selected) { pick(rows[selected].row) }
        default: return false
        }
        return true
    }

    private func pick(_ r: Row) {
        view.window?.close()
        let scripts = app.scripts, wid = self.wid
        let install = app.scripts.state.found[wid]?.options.first { $0.id == r.id }?.kind == "install"
        Task { install ? await scripts.start(wid, r.id, RunStart(worktreeId: wid, id: r.id)) : await scripts.start(choice: r.id, in: wid) }
    }
    private func stop(_ r: Row) { if let sid = r.session { Task { await app.call(SessionKill(id: sid)) } } }
    private func page(_ r: Row) {
        view.window?.close()
        r.session.map(app.scripts.openPage)
    }

    private func label(_ text: String, size: CGFloat) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .ui(size)
        l.textColor = .secondaryLabelColor
        l.maximumNumberOfLines = size > 11 ? 3 : 2
        return l
    }
}

/// The list's root: ↑ ↓ and Return reach it while the popover is up.
private final class KeyStack: NSStackView {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if onKey?(e) != true { super.keyDown(with: e) } }
}

/// One choice: its name, the command it runs (dimmed, cut at the end), and at its end ⌘R, what it lacks, or — running —
/// its page and a stop.
@MainActor
private final class PickRow: PointerControl {
    let row: RunPicker.Row
    private let run: () -> Void
    var onStop: (() -> Void)?, onPage: (() -> Void)?

    init(_ r: RunPicker.Row, run: @escaping () -> Void) {
        row = r
        self.run = run
        super.init(frame: .zero)
        layer?.cornerRadius = Metrics.radiusSM
        let name = NSTextField(labelWithString: r.name)
        name.font = .ui(12)
        name.textColor = r.missing == nil ? .labelColor : .secondaryLabelColor
        name.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        let command = NSTextField(labelWithString: r.command)
        command.font = .uiMono(11)
        command.textColor = .secondaryLabelColor
        command.lineBreakMode = .byTruncatingTail
        command.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        var views: [NSView] = [name, command, NSView()]
        if let m = r.missing { views.append(Self.small(String(localized: "\(m) isn't installed"))) }
        if let url = r.url, let port = URLComponents(string: url)?.port {
            let page = PointerButton(title: ":\(port)") { [weak self] in self?.onPage?() }
            page.font = .uiDigits(11)
            page.isBordered = false
            page.padding = 4
            page.toolTip = String(localized: "Open \(url)")
            views.append(page)
        }
        if r.session != nil {
            views.append(IconButton(.symbol("stop.fill", String(localized: "Stop")), tip: String(localized: "Stop")) { [weak self] in self?.onStop?() })
        } else if let k = r.key { views.append(Self.small(k)) }
        let line = NSStackView(views: views)
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        pin(line)
        heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.row)).isActive = true
        toolTip = r.command
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([r.name, r.command, r.session != nil ? String(localized: "running") : nil].compactMap { $0 }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func small(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .ui(11)
        l.textColor = .secondaryLabelColor
        return l
    }
    override func clicked() { run() }
    /// The row takes the click, its labels included; its buttons (the page, Stop) keep theirs.
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v is NSButton ? v : v == nil ? nil : self
    }
}
