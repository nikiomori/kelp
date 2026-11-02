import AppKit
import Core
import Agents
import DesignKit
import WorkbenchKit

/// An empty workspace: where it is, a field for the default agent's first task, and what can be opened here, one
/// click each (like Xcode's welcome window) — the installed agents, a terminal, and whatever extensions add (the browser…).
@MainActor
final class StartView: NSView {
    var onAgent: ((String) -> Void)?
    /// The default agent, started with what was typed (the workspace takes its name from it).
    var onPrompt: ((String, String) -> Void)?
    var onOpen: ((String) -> Void)?
    /// No agent on this Mac: one of the suggested ones, installed in a terminal tab here.
    var onInstall: ((AgentManifest) -> Void)?
    private lazy var prompt: StartPrompt = {
        let name = app.catalog.all.first { $0.id == def }?.name ?? def
        return StartPrompt(placeholder: String(localized: "What should \(name) do? Return starts it"),
                           accessibilityLabel: String(localized: "First task for \(name)"))
    }()
    private let def: String
    /// What's typed, kept by the area: this view is made again whenever the workspace's agents change.
    var draft: String {
        get { prompt.value }
        set { prompt.value = newValue }
    }
    var onDraft: ((String) -> Void)? {
        get { prompt.onChange }
        set { prompt.onChange = newValue }
    }
    /// The rows of the agents on show, whose plan limits follow the daemon: the view isn't made again, what's typed stays.
    private var agentRowsById: [String: StartRow] = [:]
    private let planLine = NSTextField(wrappingLabelWithString: "")
    private let planSwitch = PointerButton()
    private lazy var planBar = NSStackView(views: [planLine, planSwitch])

    private let app: AppModel
    init(app: AppModel, worktree w: Worktree) {
        self.app = app; def = app.catalog.defaultAgent
        super.init(frame: .zero)
        let repo = app.repo(w.repoId)
        let icon = NSImageView(image: .symbol("folder"))
        if let repo { ProjectIcon.show(repo.path, in: icon, app: app, initial: false) }
        icon.imageScaling = .scaleProportionallyUpOrDown; icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: app.groupName(w) ?? app.projectName(w.repoId) ?? w.displayName)
        title.font = .ui(20, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.alignment = .center
        // The window bar shows the folder; a remote project's host and path are said here, the bar has the local stand-in.
        let folder = NSTextField(labelWithString: RemoteHost.of(w.path).map { "\($0.host):\($0.path)" } ?? "")
        folder.font = .ui(13)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        folder.isHidden = folder.stringValue.isEmpty

        // The default agent first, then those in use, then the others (two columns: people often have a dozen). Six at
        // most, the rest behind one row: however many there are, Terminal stays on screen.
        let started = Set(app.sessions.map(\.agent))
        let first = def
        let rank = { (a: AgentManifest) in (a.id == first ? 0 : 1, started.contains(a.id) ? 0 : 1, a.name) }
        let agents = app.catalog.installed(app.catalog.all).sorted { rank($0) < rank($1) }
        var tiles = agents.prefix(Self.agentRows).map { a in
            let row = StartRow(image: app.catalog.icon(a.id, size: 20), title: a.name, detail: a.id == def ? String(localized: "Default") : nil,
                               shortcut: a.id == def ? "⌥⌘T" : nil) { [weak self] in self?.onAgent?(a.id) }
            agentRowsById[a.id] = row
            return row
        }
        if agents.count > Self.agentRows { tiles.append(moreAgents(Array(agents.dropFirst(Self.agentRows)))) }
        // In two columns the default agent still runs across the card, its ⌥⌘T at the right edge with ⌘T and the rest.
        let lead = agents.first?.id == def ? 1 : 0
        let rows = agentRows(agents, tiles: tiles, lead: lead)
        let others = otherRows(w)
        let card = StartCard(rows: rows, others: others)

        let open = NSTextField(labelWithString: String(localized: "Open"))
        open.font = .ui(11, weight: .semibold); open.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: String(localized: "A file, an agent or a command: ⌘P"))
        hint.font = .ui(12); hint.textColor = .secondaryLabelColor

        var views: [NSView] = [icon, title, folder]
        let field = agents.contains { $0.id == def } ? promptField() : nil
        if let field { views += [field, planBar] }
        views += [open, card, hint]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(14, after: icon); stack.setCustomSpacing(24, after: folder.isHidden ? title : folder)
        if let field {
            stack.setCustomSpacing(22, after: planBar)
        }
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
        if tiles.count > 5 {
            tiles.dropFirst(lead).forEach { $0.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.5, constant: -6).isActive = true }
        }
        followPlans(in: stack, after: field)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let agentRows = 6

    /// The agents past the first six, in a menu under its row.
    private func moreAgents(_ rest: [AgentManifest]) -> StartRow {
        weak var row: StartRow?
        let more = StartRow(image: .symbol("ellipsis.circle"), title: String(localized: "More Agents…"), shortcut: nil) { [weak self] in
            guard let self, let row else { return }
            let menu = NSMenu()
            for a in rest {
                let item = menu.add(a.name) { [weak self] in self?.onAgent?(a.id) }
                item.show(self.app.catalog.icon(a.id, size: 16))
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: row)
        }
        row = more
        return more
    }

    /// The agents to start, in two columns after the first `lead` when there are many; with none, what to install; then
    /// the catalog.
    private func agentRows(_ agents: [AgentManifest], tiles: [StartRow], lead: Int) -> [NSView] {
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
            rows += tiles.prefix(lead).map { $0 as NSView }
            let paired = Array(tiles.dropFirst(lead))
            let grid = NSGridView(numberOfColumns: 2, rows: 0)
            grid.columnSpacing = 4
            grid.rowSpacing = 0
            for i in stride(from: 0, to: paired.count, by: 2) {
                grid.addRow(with: [paired[i], i + 1 < paired.count ? paired[i + 1] : NSGridCell.emptyContentView])
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
    private func otherRows(_ w: Worktree) -> [NSView] {
        let app = self.app
        var others: [NSView] = [StartRow(image: .symbol("terminal"), title: String(localized: "Terminal"), shortcut: "⌘T") { [weak self] in
            self?.onOpen?("terminal:")
        }]
        others.append(RunSlot(app: app, workspace: w.id))
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

    private func followPlans(in stack: NSStackView, after field: NSView?) {
        // Not in the stack when the default agent isn't installed: there is no field for it to sit under.
        if field != nil { planBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        planBar.spacing = Metrics.gapWide
        planLine.font = .ui(12)
        planLine.textColor = .secondaryLabelColor
        planSwitch.padding = Metrics.gap
        planSwitch.restFill = .fillRest
        planSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        showPlans(in: stack, after: field)
        track(owner: self) { [app] in app.limits } changed: { [weak self, weak stack] _ in
            if let stack { self?.showPlans(in: stack, after: field) }
        }
    }

    /// Each agent's plan beside its name; under the field, what to know when the default agent is nearly out.
    private func showPlans(in stack: NSStackView, after field: NSView?) {
        let notes = app.planNotes
        for (id, row) in agentRowsById {
            row.show(lead: id == def ? String(localized: "Default") : nil, note: notes[id])
        }
        let name = app.catalog.all.first { $0.id == def }?.name ?? def
        let warning = notes[def]?.warning(for: name)
        planLine.stringValue = warning ?? ""
        let others = agentRowsById.keys.filter { $0 != def }
        let other = warning == nil ? nil : PlanNote.roomiest(Array(others), notes: notes)
        planBar.isHidden = warning == nil
        planSwitch.isHidden = other == nil
        if let other, let n = app.catalog.all.first(where: { $0.id == other })?.name {
            planSwitch.title = String(localized: "Start in \(n)")
            planSwitch.onClick = { [weak self] in self?.start(other) }
        }
        if let field { stack.setCustomSpacing(planBar.isHidden ? 22 : 8, after: field) }
    }

    /// With what was typed, if anything.
    private func start(_ agent: String) {
        let text = prompt.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { onAgent?(agent) } else { onPrompt?(agent, text) }
    }

    /// The default agent's icon and a field: Return starts the agent with the text.
    private func promptField() -> NSView {
        prompt.onReturn = { [weak self] typed in
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if let self, !text.isEmpty { onPrompt?(def, text) }
        }
        let icon = NSImageView(image: app.catalog.icon(def, size: 18) ?? NSImage())
        let row = NSStackView(views: [icon, prompt])
        row.spacing = 10
        row.alignment = .top
        row.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
        let box = StartBox(radius: Metrics.radiusLG)   // the prompt's field
        box.pin(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            box.heightAnchor.constraint(equalTo: prompt.heightAnchor, constant: row.edgeInsets.top + row.edgeInsets.bottom)
        ])
        return box
    }

    func focus() { if prompt.superview != nil { prompt.focus() } }

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
                (r as? RunSlot)?.before = sep
            }
            views.append(r)
        }
        let list = NSStackView(views: views)
        list.detachesHiddenViews = true   // the run rows, while there's nothing to run, and their separator
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

/// What the run chip runs (its command beside it; ⌘R once something ran in the project) and its list; gone, with the
/// separator above, while the project offers nothing to run. Follows the files as they're read.
@MainActor
private final class RunSlot: NSStackView {
    weak var before: NSView? { didSet { before?.isHidden = isHidden } }
    override var isHidden: Bool { didSet { before?.isHidden = isHidden } }

    init(app: AppModel, workspace wid: String) {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 0
        track(owner: self) { app.scripts.offer(wid) } changed: { [weak self] in self?.show($0, app, wid) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func show(_ o: ScriptsMenu.Offer?, _ app: AppModel, _ wid: String) {
        isHidden = o == nil
        guard let o else { return }
        let run = StartRow(image: .symbol("play"), title: String(localized: "Run \(o.label)"), detail: o.command, shortcut: o.guess ? nil : "⌘R") {
            Task { await app.scripts.start(choice: o.choice, in: wid) }
        }
        let choose = StartRow(image: .symbol("list.bullet"), title: String(localized: "Choose What to Run…"), shortcut: "⌃⌘R") { app.scripts.choose() }
        let sep = NSBox(); sep.boxType = .separator
        setViews([run, sep, choose], in: .top)
        for v in [run, choose] { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        sep.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true   // inset as the card's own
    }
}

/// One action: symbol, title, a detail and its shortcut on the right; highlights on hover.
@MainActor
private final class StartRow: NSView {
    private let action: () -> Void
    private var hover = false
    private let more = NSTextField(labelWithString: "")

    /// `lead` in grey; the plan in its colour after it.
    func show(lead: String?, note: PlanNote?) {
        let text = NSMutableAttributedString(string: [lead, note == nil ? nil : ""].compactMap { $0 }.joined(separator: " · "),
                                             attributes: [.font: NSFont.ui(12), .foregroundColor: NSColor.secondaryLabelColor])
        if let note { text.append(NSAttributedString(string: note.text, attributes: [.font: NSFont.ui(12), .foregroundColor: note.color])) }
        more.attributedStringValue = text
        more.isHidden = text.length == 0
    }

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
        more.stringValue = detail ?? ""
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
    override func mouseDown(with e: NSEvent) { fadeBackground(to: .fillSelected, held: true) }
    override func mouseUp(with e: NSEvent) {
        fadeBackground(to: hover ? .fillHover : nil)
        if bounds.contains(convert(e.locationInWindow, from: nil)) { pressBounce(); action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
