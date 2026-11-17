import Agents
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The empty workspace. It shows where the workspace is, a field for the default agent's first task with Make at its
/// foot, and then what can be opened here, one click each, in the "+" menu's order (`NewTabChoices`): the agents as
/// tiles with their plans, a terminal and what extensions open, and what to run.
@MainActor
final class StartView: NSView {
    var onAgent: ((String) -> Void)?
    /// Starts the default agent with what was typed (the workspace takes its name from the text).
    var onPrompt: ((String, String) -> Void)?
    var onOpen: ((String) -> Void)?
    /// When no agent is on this Mac, installs one of the suggested agents in a terminal tab here.
    var onInstall: ((AgentManifest) -> Void)?
    private lazy var prompt: StartPrompt = {
        let name = app.catalog.name(def)
        return StartPrompt(
            placeholder: String(localized: "What should \(name) do? Return starts it"),
            accessibilityLabel: String(localized: "First task for \(name)"))
    }()
    private let def: String
    /// What's typed, kept by the editor area, because this view is made again whenever the workspace's agents change.
    var draft: String {
        get { prompt.value }
        set { prompt.value = newValue }
    }
    var onDraft: ((String) -> Void)? {
        get { prompt.onChange }
        set { prompt.onChange = newValue }
    }
    /// The tiles of the agents on show, by agent id. Their plan limits follow the daemon without making the view again,
    /// so what's typed stays.
    private var tilesById: [String: AgentTile] = [:]
    /// All the tiles, including the one for the remaining agents. Either they all keep room for a plan, or none does.
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
        title.font = .ui(TextSize.title, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.alignment = .center
        // The window bar shows the folder. For a remote project the bar has the local stand-in, so the host and path
        // are given here. A group on a branch says so, because its code isn't the project's.
        let onBranch =
            repo.map { $0.path != w.path } == true
            ? String(
                localized: "On its own branch \(w.branch), from \(w.base.isEmpty ? repo?.baseBranch ?? "" : w.base)")
            : ""
        let folder = NSTextField(
            labelWithString: RemoteHost.of(w.path).map { "\($0.host):\($0.path)" } ?? onBranch)
        folder.font = .ui(TextSize.body)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        folder.isHidden = folder.stringValue.isEmpty

        let agents = NewTabChoices.agents(app)
        let hint = NSTextField(labelWithString: String(localized: "A file, an agent or a command: ⌘P"))
        hint.font = .ui(TextSize.row)
        hint.textColor = .secondaryLabelColor

        var views: [NSView] = [icon, title, folder]
        let code = codeChoice(w, repo)
        if let code { views.append(code) }
        let field = agents.contains { $0.id == def } ? promptField() : nil
        if let field { views += [field, planBar] }
        let templates = TemplateGroup(app: app, workspace: w)
        views.append(templates)
        let agentsHead = Self.heading(String(localized: "Agents")), openHead = Self.heading(String(localized: "Open"))
        let agentList = agents.isEmpty ? StartCard(rows: installRows()) : tiles(agents)
        // The card is made again when what it offers changes (Database, once the workspace's databases are read).
        let openCard = NSStackView()
        let choices = { [weak self] in NewTabChoices.open(app, w) { self?.onOpen?(TabURI.terminal()) } }
        track(owner: openCard) {
            choices().map(\.title)
        } changed: { [weak openCard] _ in
            guard let openCard else { return }
            let card = StartCard(rows: choices().map(StartRow.init), columns: 2)
            openCard.setViews([card], in: .top)
            card.widthAnchor.constraint(equalTo: openCard.widthAnchor).isActive = true
        }
        let run = RunGroup(app: app, workspace: w.id)
        views += [agentsHead, agentList, openHead, openCard, run, hint]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(code == nil ? 24 : Metrics.inset, after: folder.isHidden ? title : folder)
        if let code { stack.setCustomSpacing(24, after: code) }
        if let field { stack.setCustomSpacing(22, after: field) }
        for (head, after) in [(agentsHead, 6), (openHead, 6)] as [(NSView, CGFloat)] {
            stack.setCustomSpacing(after, after: head)
        }
        stack.setCustomSpacing(18, after: agentList)
        stack.setCustomSpacing(18, after: templates)
        stack.setCustomSpacing(14, after: run)
        // The page sits in a scroll view, so a low window scrolls the list rather than growing to hold it.
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
        // The stack sits a little above the middle; in a low window it starts at the top instead of going under it.
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
        // Each group's heading starts over its rows' icons, and the field, the tiles and the cards are as wide as the
        // page.
        for head in [agentsHead, openHead, run.head] {
            head.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Self.headInset).isActive = true
        }
        for part in [field, templates, agentList, openCard, run].compactMap({ $0 }) {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        followPlans(in: stack, after: field)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// For a group in the project's folder with nothing on it yet, the choice of where its code lives. It can share the
    /// project's folder (a group splits the screen), or get a branch of its own in its own folder (a branch splits the
    /// code). The branch is made when picked, and this empty group goes as the screen moves to the branch's group.
    /// Beside the choice is a branch that's already there, or a pull request. Returns nil for the project's own screen,
    /// a group already on a branch, and a project on a host.
    private func codeChoice(_ worktree: Worktree, _ repo: Repo?) -> NSView? {
        guard let repo, app.groupName(worktree) != nil, worktree.path == repo.path, RemoteHost.of(repo.path) == nil
        else {
            return nil
        }
        let app = self.app
        let label = NSTextField(labelWithString: String(localized: "Code"))
        label.font = .ui(TextSize.row)
        label.textColor = .secondaryLabelColor
        let place = NSSegmentedControl(
            labels: [String(localized: "Project Folder"), String(localized: "Own Branch")],
            trackingMode: .selectOne, target: nil, action: nil)
        place.segmentDistribution = .fit
        place.controlSize = .small
        place.selectedSegment = 0
        place.setToolTip(String(localized: "Shares the project’s files with its other chats"), forSegment: 0)
        place.setToolTip(
            String(localized: "A new branch from \(repo.baseBranch) in a folder of its own"), forSegment: 1)
        // Once Own Branch is picked, the screen moves to the branch's group.
        let pick = ClosureTarget { [weak place] in
            guard place?.selectedSegment == 1 else { return }
            place?.isEnabled = false
            app.workbench.newBranch(repo: repo.id)
        }
        place.target = pick
        place.action = #selector(ClosureTarget.fire)
        codePick = pick
        let other = TextButton(String(localized: "Choose Branch…")) {
            app.workbench.newBranchAsking(repo: repo.id)
        }
        other.toolTip = String(localized: "A branch with a name, one that’s there, or a pull request")
        let row = NSStackView(views: [label, place, other])
        row.spacing = Metrics.gapWide
        return row
    }
    private var codePick: ClosureTarget?   // kept here because a control doesn't retain its target

    /// Where a group's heading starts: over the icons of its rows.
    static let headInset = StartCard.inset + StartRow.inset

    static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .ui(TextSize.caption, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Lays out the first six agents as tiles, four to a row, then one tile for the rest (a menu with the catalog at
    /// its foot), or the catalog when there are no others.
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

    /// The rows shown when no agent is on this Mac: what to install, then the catalog.
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

    /// Sets up the plan warning and keeps the plans current as the limits change. `under` is the view the warning sits
    /// under (the field), or nil when the default agent isn't installed.
    private func followPlans(in stack: NSStackView, after under: NSView?) {
        if under != nil {
            planBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(22, after: planBar)
        }
        planBar.spacing = Metrics.gapWide
        planLine.font = .ui(TextSize.row)
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

    /// Shows each agent's plan on its tile, and under the field what to know when the default agent is nearly out.
    private func showPlans(in stack: NSStackView, after under: NSView?) {
        let plans = app.extensions.all.plans
        let notes = plans?.notes() ?? [:]
        for (id, tile) in tilesById { tile.show(notes[id]) }
        let anyPlan = tilesById.keys.contains { notes[$0] != nil }
        for tile in allTiles { tile.roomForPlan = anyPlan }
        let name = app.catalog.name(def)
        let warning = plans?.warning(def, name, tilesById.keys.filter { $0 != def })
        planLine.stringValue = warning?.text ?? ""
        let other = warning?.instead
        planBar.isHidden = warning == nil
        planSwitch.isHidden = other == nil
        if let other, let otherName = app.catalog.all.first(where: { $0.id == other })?.name {
            planSwitch.title = String(localized: "Start in \(otherName)")
            planSwitch.onClick = { [weak self] in self?.start(other) }
        }
        if let under { stack.setCustomSpacing(planBar.isHidden ? 22 : Metrics.gapWide, after: under) }
    }

    /// Starts the agent with what was typed, if anything.
    private func start(_ agent: String) {
        let text = prompt.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { onAgent?(agent) } else { onPrompt?(agent, text) }
    }

    /// Builds the field: the default agent's icon and the text, where Return starts the agent with the text. Make sits
    /// in the field's foot, under a line, and each chip fills the field.
    private func promptField() -> NSView {
        prompt.onReturn = { [weak self] typed in
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if let self, !text.isEmpty { onPrompt?(def, text) }
        }
        let icon = NSImageView(image: app.catalog.icon(def, size: 18) ?? NSImage())
        let row = NSStackView(views: [icon, prompt])
        row.spacing = Metrics.gapWide
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

    /// Puts the Make line in the field with the caret after it, because what to make is the user's to say.
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
