import Agents
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// An empty workspace: where it is, a field for the default agent's first task with Make in its foot, then what can be
/// opened here, one click each, in the "+" menu's order (`NewTabChoices`): the agents as tiles with their plans, a
/// terminal and what extensions open, what to run.
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
        return StartPrompt(
            placeholder: String(localized: "What should \(name) do? Return starts it"),
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
    /// The tiles of the agents on show, whose plan limits follow the daemon: the view isn't made again, what's typed stays.
    private var tilesById: [String: AgentTile] = [:]
    /// All the tiles, the one for the rest too: they keep room for a plan together, or none does.
    private var allTiles: [AgentTile] = []
    private let planLine = NSTextField(wrappingLabelWithString: "")
    private let planSwitch = PointerButton()
    private lazy var planBar = NSStackView(views: [planLine, planSwitch])

    private let app: AppModel
    init(app: AppModel, worktree w: Worktree) {
        self.app = app
        def = app.catalog.defaultAgent
        super.init(frame: .zero)
        let repo = app.repo(w.repoId)
        let icon = NSImageView(image: .symbol("folder"))
        if let repo { ProjectIcon.show(repo.path, in: icon, app: app, initial: false) }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = .chrome(Metrics.iconHero)
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

        let agents = NewTabChoices.agents(app)
        let open = NewTabChoices.open(app, w) { [weak self] in self?.onOpen?("terminal:") }
        let hint = NSTextField(labelWithString: String(localized: "A file, an agent or a command: ⌘P"))
        hint.font = .ui(12)
        hint.textColor = .secondaryLabelColor

        var views: [NSView] = [icon, title, folder]
        let field = agents.contains { $0.id == def } ? promptField() : nil
        if let field { views += [field, planBar] }
        let agentsHead = Self.heading(String(localized: "Agents")), openHead = Self.heading(String(localized: "Open"))
        let agentList = agents.isEmpty ? StartCard(rows: installRows()) : tiles(agents)
        let openCard = StartCard(rows: open.map(StartRow.init), columns: 2)
        let run = RunGroup(app: app, workspace: w.id)
        views += [agentsHead, agentList, openHead, openCard, run, hint]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(24, after: folder.isHidden ? title : folder)
        if let field { stack.setCustomSpacing(22, after: field) }
        for (head, after) in [(agentsHead, 6), (openHead, 6)] as [(NSView, CGFloat)] {
            stack.setCustomSpacing(after, after: head)
        }
        stack.setCustomSpacing(18, after: agentList)
        stack.setCustomSpacing(14, after: run)
        // In a scroll view: a low window scrolls the list rather than growing to hold it.
        let page = FlippedView()
        page.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = page
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        pin(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 460)
        width.priority = .defaultHigh
        // A little above the middle; in a low window it starts at the top instead of going under it.
        let middle = stack.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -30)
        middle.priority = .defaultHigh
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            page.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            page.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor).withPriority(
                NSLayoutConstraint.Priority.defaultLow.rawValue),
            stack.centerXAnchor.constraint(equalTo: page.centerXAnchor), middle,
            stack.topAnchor.constraint(greaterThanOrEqualTo: page.topAnchor, constant: 24),
            page.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 24),
            width, stack.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            folder.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        // The groups' headings over their rows' icons; the field, the tiles and the cards as wide as the page.
        for head in [agentsHead, openHead, run.head] {
            head.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Self.headInset).isActive = true
        }
        for part in [field, agentList, openCard, run].compactMap({ $0 }) {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        followPlans(in: stack, after: field)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where a group's heading starts: over the icons of its rows.
    static let headInset = StartCard.inset + StartRow.inset

    static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .ui(11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// The first six agents as tiles, four to a row, then one for the rest (a menu, the catalog at its foot) or, when
    /// there's no rest, the catalog.
    private func tiles(_ agents: [AgentManifest]) -> NSView {
        let app = self.app
        var all: [AgentTile] = agents.prefix(NewTabChoices.shown).map { agent in
            let key = agent.id == def ? NewTabChoices.defaultKey(app).map(KeyBindings.display) : nil
            let tile = AgentTile(
                image: app.catalog.icon(agent.id, size: Metrics.iconEmpty), title: agent.name, key: key,
                isDefault: agent.id == def
            ) { [weak self] in
                self?.start(agent.id)
            }
            tilesById[agent.id] = tile
            return tile
        }
        let rest = Array(agents.dropFirst(NewTabChoices.shown))
        let catalog: @MainActor () -> Void = { SettingsWindow.show(app, section: "catalog") }
        if rest.isEmpty {
            all.append(
                AgentTile(
                    image: .symbol("square.grid.2x2"), title: String(localized: "Agent Catalog…"), key: nil,
                    isDefault: false, action: catalog))
        } else {
            weak var tile: AgentTile?
            let icons = rest.prefix(3).map { app.catalog.icon($0.id, size: Metrics.iconMenu) }
            let more = AgentTile(stack: icons, title: String(localized: "\(rest.count) More")) { [weak self] in
                guard let self, let tile else { return }
                let menu = NSMenu()
                for agent in rest {
                    menu.add(agent.name) { [weak self] in self?.start(agent.id) }.show(app.catalog.icon(agent.id))
                }
                menu.addItem(.separator())
                menu.add(String(localized: "Agent Catalog…"), catalog).show(.symbol("square.grid.2x2"))
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: tile.bounds.height + 4), in: tile)
            }
            more.setAccessibilityLabel(String(localized: "More Agents…"))
            tile = more
            all.append(more)
        }
        allTiles = all
        let rows = stride(from: 0, to: all.count, by: Self.perRow).map { first in
            let row = NSStackView(views: (first..<first + Self.perRow).map { $0 < all.count ? all[$0] : NSView() })   // a short last row keeps the width
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = Metrics.gap
            return row as NSView
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.spacing = Metrics.gap
        for row in rows { row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
        return grid
    }
    private static let perRow = 4

    /// No agent on this Mac: what to install, then the catalog.
    private func installRows() -> [NSView] {
        let app = self.app
        let none = NSTextField(
            wrappingLabelWithString: String(
                localized:
                    "No agent found on this Mac. Install one: its installer runs in a terminal here, and the agent is offered when it’s done."
            ))
        none.textColor = .secondaryLabelColor
        var rows: [NSView] = [StartView.padded(none)]
        rows += app.catalog.suggested.map { agent in
            StartRow(
                image: app.catalog.icon(agent.id, size: 20), title: agent.name, detail: app.catalog.about(agent.id),
                shortcut: nil
            ) { [weak self] in
                self?.onInstall?(agent)
            }
        }
        // Installing, updating and setting up agents is the catalog's (Settings), not something the "+" menu starts.
        rows.append(
            StartRow(image: .symbol("square.grid.2x2"), title: String(localized: "Agent Catalog…"), shortcut: nil) {
                SettingsWindow.show(app, section: "catalog")
            })
        return rows
    }

    /// `under`: what the warning sits under (the field); nil when the default agent isn't installed.
    private func followPlans(in stack: NSStackView, after under: NSView?) {
        if under != nil {
            planBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(22, after: planBar)
        }
        planBar.spacing = Metrics.gapWide
        planLine.font = .ui(12)
        planLine.textColor = .secondaryLabelColor
        planSwitch.padding = Metrics.gap
        planSwitch.restFill = .fillRest
        planSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        showPlans(in: stack, after: under)
        track(owner: self) { [app] in
            app.latest(LimitsEvent.self)?.usage
        } changed: { [weak self, weak stack] _ in
            if let stack { self?.showPlans(in: stack, after: under) }
        }
    }

    /// Each agent's plan on its tile; under the field, what to know when the default agent is nearly out.
    private func showPlans(in stack: NSStackView, after under: NSView?) {
        let notes = PlanNote.notes(app)
        for (id, tile) in tilesById { tile.show(notes[id]) }
        let anyPlan = tilesById.keys.contains { notes[$0] != nil }
        for tile in allTiles { tile.roomForPlan = anyPlan }
        let name = app.catalog.all.first { $0.id == def }?.name ?? def
        let warning = notes[def]?.warning(for: name)
        planLine.stringValue = warning ?? ""
        let others = tilesById.keys.filter { $0 != def }
        let other = warning == nil ? nil : PlanNote.roomiest(Array(others), notes: notes)
        planBar.isHidden = warning == nil
        planSwitch.isHidden = other == nil
        if let other, let otherName = app.catalog.all.first(where: { $0.id == other })?.name {
            planSwitch.title = String(localized: "Start in \(otherName)")
            planSwitch.onClick = { [weak self] in self?.start(other) }
        }
        if let under { stack.setCustomSpacing(planBar.isHidden ? 22 : Metrics.gapWide, after: under) }
    }

    /// With what was typed, if anything.
    private func start(_ agent: String) {
        let text = prompt.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { onAgent?(agent) } else { onPrompt?(agent, text) }
    }

    /// The default agent's icon and a field: Return starts the agent with the text. Make in its foot, under a line:
    /// each chip fills the field.
    private func promptField() -> NSView {
        prompt.onReturn = { [weak self] typed in
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if let self, !text.isEmpty { onPrompt?(def, text) }
        }
        let icon = NSImageView(image: app.catalog.icon(def, size: 18) ?? NSImage())
        let row = NSStackView(views: [icon, prompt])
        row.spacing = 10
        row.alignment = .top
        let line = NSBox()
        line.boxType = .separator
        let make = MakeChips { [weak self] k in self?.draftMake(k) }
        let column = NSStackView(views: [row, line, make])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.gapWide
        column.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: Metrics.gapWide, right: 12)
        let box = StartBox(radius: Metrics.radiusLG)   // the prompt's field
        box.pin(column)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24),
            line.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24)
        ])
        return box
    }

    func focus() { if prompt.superview != nil { prompt.focus() } }

    /// The Make line in the field, the caret after it: what to make is the user's to say.
    private func draftMake(_ kind: Make.Kind) {
        prompt.value = Make.line(kind)
        prompt.focus()
    }

    static func padded(_ content: NSView) -> NSView {
        let stack = NSStackView(views: [content])
        stack.edgeInsets = NSEdgeInsets(top: 10, left: headInset, bottom: 10, right: headInset)
        return stack
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
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.fillRest.cgColor
    }
}

/// Choices in one grouped box, like a Settings list, a line between rows; in `columns: 2`, two to a row.
@MainActor
private final class StartCard: NSView {
    /// The card's edge to its rows' highlight.
    static let inset: CGFloat = 4

    init(rows: [NSView], columns: Int = 1) {
        super.init(frame: .zero)
        let box = StartBox(radius: Metrics.radiusXL)   // the card
        let lines: [NSView] =
            columns == 1
            ? rows
            : stride(from: 0, to: rows.count, by: columns).map { first in
                let pair = NSStackView(views: (first..<first + columns).map { $0 < rows.count ? rows[$0] : NSView() })
                pair.distribution = .fillEqually
                pair.spacing = Self.inset
                return pair
            }
        var views: [NSView] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                views.append(sep)
            }
            views.append(line)
        }
        let list = NSStackView(views: views)
        list.orientation = .vertical
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        pin(box)
        pin(list)
        for view in views {
            if view is NSBox {
                view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -40).isActive = true
            }   // inset like grouped lists
            else {
                view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -2 * Self.inset).isActive = true
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// What the run chip runs and its list, under a heading of their own; gone while the project offers nothing to run.
/// Follows the files as they're read.
@MainActor
private final class RunGroup: NSStackView {
    let head = StartView.heading(String(localized: "Run"))

    init(app: AppModel, workspace wid: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 0, right: 0)
        // The rows again when what they say changes.
        track(owner: self) {
            (app.extensions.all.runs?.choices(wid) ?? []).map { [$0.title, $0.help ?? "", $0.key?.description ?? ""] }
        } changed: { [weak self] _ in
            self?.show(app.extensions.all.runs?.choices(wid) ?? [])
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func show(_ run: [NewTabChoices.Action]) {
        isHidden = run.isEmpty
        let card = StartCard(rows: run.map(StartRow.init), columns: 2)
        setViews([head, card], in: .top)
        head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: StartView.headInset).isActive = true
        card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

/// One action: symbol, title, a detail and its shortcut on the right; highlights on hover.
@MainActor
private final class StartRow: PointerControl {
    private let run: () -> Void

    /// The edge of the row's highlight to its icon.
    static let inset: CGFloat = 10

    convenience init(_ a: NewTabChoices.Action) {
        self.init(image: .symbol(a.symbol), title: a.title, shortcut: a.key.map(KeyBindings.display), action: a.run)
        toolTip = a.help
    }

    init(image: NSImage?, title: String, detail: String? = nil, shortcut: String?, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        layer?.cornerRadius = Metrics.radiusMD
        let icon = NSImageView(image: image ?? NSImage())
        icon.symbolConfiguration = .chrome(Metrics.iconLarge)
        icon.contentTintColor = .secondaryLabelColor   // symbols only; real icons keep their colors
        let label = NSTextField(labelWithString: title)
        label.font = .ui(13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let more = NSTextField(labelWithString: detail ?? "")
        more.textColor = .secondaryLabelColor
        more.font = .ui(12)
        more.lineBreakMode = .byTruncatingTail
        more.setContentCompressionResistancePriority(.init(240), for: .horizontal)   // the name wins
        let key = NSTextField(labelWithString: shortcut ?? "")
        key.textColor = .secondaryLabelColor
        key.font = .ui(12)
        let row = NSStackView(views: [icon, label, NSView(), more, key])
        row.spacing = 10
        row.detachesHiddenViews = true
        more.isHidden = detail == nil
        key.isHidden = shortcut == nil
        row.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: Self.inset)
        pin(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.rowCard)),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconButton)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func clicked() { run() }
}
