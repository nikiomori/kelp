import AppKit
import Core
import Agents
import DesignKit
import WorkbenchKit

/// An empty workspace: where it is, a field for the default agent's first task, and what can be opened here, one
/// click each (like Xcode's welcome window) — the installed agents, a terminal, and whatever extensions add (the browser…).
@MainActor
final class StartView: NSView, NSTextFieldDelegate {
    var onAgent: ((String) -> Void)?
    /// The default agent, started with what was typed (the workspace takes its name from it).
    var onPrompt: ((String, String) -> Void)?
    var onOpen: ((String) -> Void)?
    /// No agent on this Mac: one of the suggested ones, installed in a terminal tab here.
    var onInstall: ((AgentManifest) -> Void)?
    private let prompt = NSTextField()
    private let def: String

    private let app: AppModel
    init(app: AppModel, worktree w: Worktree) {
        self.app = app; def = app.catalog.defaultAgent
        super.init(frame: .zero)
        let repo = app.repo(w.repoId)
        let icon = NSImageView(image: .symbol("folder"))
        if let repo { ProjectIcon.show(repo.path, in: icon, app: app) }
        icon.imageScaling = .scaleProportionallyUpOrDown; icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: w.displayName)
        title.font = .ui(20, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.alignment = .center
        // The window bar shows the folder; a remote project's host and path are said here, the bar has the local stand-in.
        let folder = NSTextField(labelWithString: RemoteHost.of(w.path).map { "\($0.host):\($0.path)" } ?? "")
        folder.font = .ui(13)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        folder.isHidden = folder.stringValue.isEmpty

        // The default agent first, then the others (two columns when there are many: people often have a dozen).
        let agents = app.catalog.installed(app.catalog.all).sorted { ($0.id == def ? 0 : 1, $0.name) < ($1.id == def ? 0 : 1, $1.name) }
        // In two columns there's no room for "Default" beside the name (first place and ⌥⌘T say it); the name always fits.
        let tiles = agents.map { a in
            StartRow(image: app.catalog.icon(a.id, size: 20), title: a.name, detail: a.id == def && agents.count <= 5 ? String(localized: "Default") : nil,
                     shortcut: a.id == def ? "⌥⌘T" : nil) { [weak self] in self?.onAgent?(a.id) }
        }
        let rows = agentRows(agents, tiles: tiles)
        let others = otherRows(w)
        let card = StartCard(rows: rows, others: others)

        let open = NSTextField(labelWithString: String(localized: "Open"))
        open.font = .ui(11, weight: .semibold); open.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: String(localized: "A file, an agent or a command: ⌘P"))
        hint.font = .ui(12); hint.textColor = .secondaryLabelColor

        var views: [NSView] = [icon, title, folder]
        let field = agents.contains { $0.id == def } ? promptField() : nil
        if let field { views.append(field) }
        views += [open, card, hint]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(14, after: icon); stack.setCustomSpacing(24, after: folder.isHidden ? title : folder)
        if let field { stack.setCustomSpacing(22, after: field) }
        stack.setCustomSpacing(6, after: open); stack.setCustomSpacing(14, after: card)
        // In a scroll view: a low window scrolls the list rather than growing to hold it.
        let page = FlippedView(); page.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = page
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        pin(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 460); width.priority = .defaultHigh
        // A little above the middle; in a low window it starts at the top instead of going under it.
        let middle = stack.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -30); middle.priority = .defaultHigh
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            page.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            page.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor).withPriority(NSLayoutConstraint.Priority.defaultLow.rawValue),
            stack.centerXAnchor.constraint(equalTo: page.centerXAnchor), middle, stack.topAnchor.constraint(greaterThanOrEqualTo: page.topAnchor, constant: 24),
            page.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 24),
            width, stack.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor), folder.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor), open.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 4)
        ])
        if let field { field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if tiles.count > 5 { tiles.forEach { $0.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.5, constant: -6).isActive = true } }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The agents to start, in two columns when there are many; with none, what to install; then the catalog.
    private func agentRows(_ agents: [AgentManifest], tiles: [StartRow]) -> [NSView] {
        let app = self.app
        var rows: [NSView] = []
        if agents.isEmpty {
            let none = NSTextField(wrappingLabelWithString: String(localized: "No agent found on this Mac. Install one: its installer runs in a terminal here, and the agent is offered when it’s done."))
            none.textColor = .secondaryLabelColor
            rows.append(StartView.padded(none))
            rows += app.catalog.suggested.map { m in
                StartRow(image: app.catalog.icon(m.id, size: 20), title: m.name, detail: app.catalog.about(m.id), shortcut: nil) { [weak self] in
                    self?.onInstall?(m)
                }
            }
        } else if tiles.count > 5 {
            let grid = NSGridView(numberOfColumns: 2, rows: 0)
            grid.columnSpacing = 4
            grid.rowSpacing = 0
            for i in stride(from: 0, to: tiles.count, by: 2) {
                grid.addRow(with: [tiles[i], i + 1 < tiles.count ? tiles[i + 1] : NSGridCell.emptyContentView])
            }
            rows.append(grid)
        } else {
            rows += tiles
        }
        // Installing, updating and setting up agents is the catalog's (Settings), not something the "+" menu starts.
        rows.append(StartRow(image: .symbol("square.grid.2x2"), title: String(localized: "Agent Catalog…"), shortcut: nil) {
            SettingsWindow.show(app, section: "catalog")
        })
        return rows
    }

    /// What else opens here: a terminal, a tmux session, what extensions open.
    private func otherRows(_ w: Worktree) -> [StartRow] {
        let app = self.app
        var others = [StartRow(image: .symbol("terminal"), title: String(localized: "Terminal"), shortcut: "⌘T") { [weak self] in self?.onOpen?("terminal:") }]
        if app.catalog.hasTmux(w) {
            others.append(StartRow(image: .symbol("rectangle.split.3x1"), title: String(localized: "tmux Session"), shortcut: nil) { app.quickOpen.showTmux() })
        }
        // Changes live in Source Control; the rest of what extensions open is offered here.
        for e in app.extensions.all.editors where e.id != "git.review" {
            let key = app.extensions.command(e.id)?.key.flatMap(KeySpec.init).map(KeyBindings.display)
            others.append(StartRow(image: .symbol(e.icon), title: e.title, shortcut: key) { e.open(IDEContext.of(app), in: app) })
        }
        return others
    }

    /// The default agent's icon and a field: Return starts the agent with the text.
    private func promptField() -> NSView {
        let name = app.catalog.all.first { $0.id == def }?.name ?? def
        prompt.placeholderString = String(localized: "What should \(name) do? Return starts it")
        prompt.isBordered = false
        prompt.drawsBackground = false
        prompt.focusRingType = .none
        prompt.font = .ui(14)
        prompt.lineBreakMode = .byTruncatingTail; prompt.delegate = self
        prompt.setAccessibilityLabel(String(localized: "First task for \(name)"))
        let icon = NSImageView(image: app.catalog.icon(def, size: 18) ?? NSImage())
        let row = NSStackView(views: [icon, prompt])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let box = StartBox(radius: Metrics.radiusLG)   // the prompt's field
        row.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(row)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 40), icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor), row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        return box
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        let text = prompt.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onPrompt?(def, text) }
        return true
    }

    func focus() { if prompt.superview != nil { window?.makeFirstResponder(prompt) } }

    static func padded(_ v: NSView) -> NSView {
        let p = NSStackView(views: [v]); p.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return p
    }
}

/// A rounded box in the system's grouped style: a soft fill and a hairline.
@MainActor
private final class StartBox: NSView {
    private let radius: CGFloat
    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = radius; layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.fillRest.cgColor
    }
}

/// The choices in one grouped box, like a Settings list: the agents, a line, then the terminal and the rest.
@MainActor
private final class StartCard: NSView {
    init(rows: [NSView], others: [NSView]) {
        super.init(frame: .zero)
        let box = StartBox(radius: Metrics.radiusXL)   // the card
        var views: [NSView] = []
        for (i, r) in (rows + others).enumerated() {
            if i > 0 {
                let sep = NSBox(); sep.boxType = .separator
                views.append(sep)
            }
            views.append(r)
        }
        let list = NSStackView(views: views)
        list.orientation = .vertical
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        pin(box); pin(list)
        for v in views {
            if v is NSBox { v.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -40).isActive = true }   // inset like grouped lists
            else if !(v is NSGridView) { v.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -8).isActive = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One action: symbol, title, a detail and its shortcut on the right; highlights on hover.
@MainActor
private final class StartRow: NSView {
    private let action: () -> Void
    private var hover = false

    init(image: NSImage?, title: String, detail: String? = nil, shortcut: String?, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.radiusMD; layer?.cornerCurve = .continuous
        let icon = NSImageView(image: image ?? NSImage()); icon.symbolConfiguration = .init(pointSize: 15, weight: Metrics.iconWeight)
        icon.contentTintColor = .secondaryLabelColor   // symbols only; real icons keep their colors
        let label = NSTextField(labelWithString: title)
        label.font = .ui(13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let more = NSTextField(labelWithString: detail ?? "")
        more.textColor = .secondaryLabelColor
        more.font = .ui(12)
        more.lineBreakMode = .byTruncatingTail; more.setContentCompressionResistancePriority(.init(240), for: .horizontal)   // the name wins
        let key = NSTextField(labelWithString: shortcut ?? "")
        key.textColor = .secondaryLabelColor
        key.font = .ui(12)
        let row = NSStackView(views: [icon, label, NSView(), more, key])
        row.spacing = 10
        row.detachesHiddenViews = true
        more.isHidden = detail == nil; key.isHidden = shortcut == nil
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        pin(row)
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 36), icon.widthAnchor.constraint(equalToConstant: 22)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { hover = true; fadeBackground(to: .fillHover) }
    override func mouseExited(with e: NSEvent) { hover = false; fadeBackground(to: nil) }
    override func mouseDown(with e: NSEvent) { fadeBackground(to: .fillSelected) }
    override func mouseUp(with e: NSEvent) {
        fadeBackground(to: hover ? .fillHover : nil)
        if bounds.contains(convert(e.locationInWindow, from: nil)) { pressBounce(); action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
