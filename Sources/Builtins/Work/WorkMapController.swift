import AppKit
import Core
import DesignKit
import KelpKit

/// The Map tab's controller: its bar (the turn or the whole session, which agent, zoom), the tree in a scroll
/// view that zooms, the card a node shows under the pointer, and what a click on a node does.
@MainActor
final class WorkMapController: NSViewController {
    let app: AppModel
    let model: WorkModel
    let tree = WorkMapView()
    private let scroll = NSScrollView()
    private let turnPop = NSPopUpButton()
    private let agents = AgentPicker()
    private let now = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    private let empty = EmptyStateView()
    private let loading = LoadingView(rows: true)
    private let card = HoverPopover()
    private var watched: Watched?
    private var opened: Set<String> = []
    /// What the view was last fitted to (turn, scope, agents): a new choice fits the tree again.
    private var fitted: String?
    private let session: String

    init(app: AppModel, session: String, choices: WorkChoices) {
        self.app = app
        self.session = session
        model = WorkModel(app: app, choices: choices)
        super.init(nibName: nil, bundle: nil)
        model.show(session)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        agents.onPick = { [weak self] in self?.model.picked = $0 }
        agents.trailing = false
        agents.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        agents.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        turnPop.target = self
        turnPop.action = #selector(pickTurn)
        turnPop.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        turnPop.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.formLabel + 2 * Metrics.blockGap).isActive =
            true
        let zoomOut = IconButton(.symbol("minus.magnifyingglass"), tip: String(localized: "Zoom Out")) { [weak self] in
            self?.zoom(by: 0.8)
        }
        let fit = IconButton(
            .symbol("arrow.up.left.and.down.right.magnifyingglass"), tip: String(localized: "Zoom to Fit")
        ) { [weak self] in self?.fit(animated: true) }
        let zoomIn = IconButton(.symbol("plus.magnifyingglass"), tip: String(localized: "Zoom In")) { [weak self] in
            self?.zoom(by: 1.25)
        }
        let header = Bar.content([turnPop, agents, now], [zoomOut, fit, zoomIn])
        scroll.documentView = tree
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.3
        scroll.maxMagnification = 2
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        tree.onActivate = { [weak self] in self?.activate($0) }
        tree.onHover = { [weak self] node, rect in self?.hover(node, rect) }
        let column = NSStackView(views: [header, scroll])
        column.orientation = .vertical
        column.spacing = 0
        for part in column.arrangedSubviews { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let root = NSView()
        root.pin(column)
        empty.place(in: root, under: header)
        loading.place(in: root, under: header)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        watched = Watched(.work, in: app)
        track(owner: self) { [weak self] in
            guard let self else { return Values(String?.none, Int?.none, false) }
            return Values(app.latest(WorkEvent.self, session)?.stamp, model.turn, model.whole)
        } changed: { [weak self] _ in
            self?.reload()
        }
        track(owner: self) { [weak self] in
            Values(
                self?.model.work, self?.model.picked, self?.model.error,
                self.flatMap { $0.app.session($0.session)?.status })
        } changed: {
            [weak self] _ in
            self?.render()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        watched?.key = session
        reload()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        watched?.key = nil
        card.close()
    }

    private func reload() {
        guard view.window != nil else { return }
        model.load()
    }

    private func render() {
        let work = model.work
        fillTurns(work)
        if let error = model.error, work == nil {
            empty.showError(String(localized: "Couldn’t read where the agent worked"), text: error)
            scroll.isHidden = true
            return
        }
        loading.show(work == nil && !model.loaded ? String(localized: "Reading where the agent worked…") : nil)
        guard let work else {
            empty.show(
                model.loaded ? String(localized: "No Transcript to Read") : nil, symbol: "map",
                text: String(localized: "This agent keeps no transcript Kelp can read, or its host isn’t connected."))
            scroll.isHidden = model.loaded
            return
        }
        let project = WorkTree.project(work, rootName: model.projectName, agents: model.agents)
        let outside = WorkTree.outside(work, agents: model.agents)
        guard !project.children.isEmpty || !outside.isEmpty else {
            empty.show(
                String(localized: "Nothing Touched Yet"), symbol: "map",
                text: String(localized: "Files and places show up here as the agent works."))
            scroll.isHidden = true
            return
        }
        empty.show(nil)
        scroll.isHidden = false
        agents.show(AgentPicker.entries(work, names: model.agentNames), picked: model.picked)
        let names = model.agentNames
        tree.names = names
        tree.agents = work.agents
        tree.icons = model.icons(size: Metrics.iconSmall)
        tree.agentIcon = app.session(session).flatMap { app.catalog.icon($0.agent, size: Metrics.iconMenu) }
        let working = app.session(session)?.status == .working
        now.stringValue = WorkSummary.now(work, working: working, names: names) ?? ""
        let nodes = NodeTree.nodes(project: project, outside: outside, opened: opened)
        tree.nodes = nodes
        tree.now = work.now.flatMap { work.places.indices.contains($0) ? work.places[$0] : nil }.flatMap { place in
            Self.visible(place, in: nodes)
        }
        let choice = "\(model.turn ?? -1) \(model.whole) \(model.picked ?? "")"
        if choice != fitted {
            fitted = choice
            view.layoutSubtreeIfNeeded()
            fit(animated: false)
        }
    }

    /// The node standing for a place: its own, or the folded folder it is in.
    static func visible(_ place: AgentWork.Place, in nodes: [MapNode]) -> String? {
        if [.file, .folder].contains(place.kind) {
            var path = place.name
            while !path.isEmpty {
                if nodes.contains(where: { $0.id == path }) { return path }
                path = (path as NSString).deletingLastPathComponent
            }
            return "project"
        }
        return "outside/" + place.kind.rawValue + "/" + place.name
    }

    private func fillTurns(_ work: AgentWork?) { TurnMenu.fill(turnPop, work: work, model: model) }

    // MARK: Actions

    @objc private func pickTurn() { TurnMenu.pick(turnPop, model: model) }

    private func activate(_ node: MapNode) {
        switch node.kind {
        case .file: node.place.map { model.open($0, diff: NSEvent.modifierFlags.contains(.option)) }
        case .outside: node.place.map(model.open(outside:))
        case .folded, .more:
            guard let path = node.opens else { return }
            opened.insert(path)
            render()
        case .folder:
            guard opened.contains(node.id) else { return }
            opened.remove(node.id)
            render()
        case .agent: app.workbench.focus(session: session)
        case .group: break
        }
    }

    private func hover(_ node: MapNode?, _ rect: NSRect) {
        guard let node, node.kind == .file || node.kind == .outside, let place = node.place else {
            return card.closeSoon(unlessInside: true)   // the pointer may be on its way to the card's buttons
        }
        card.open { [weak self] in
            guard let self else { return }
            let content = WorkCard(
                place: place, names: model.agentNames, icons: tree.icons, opens: model.opens(place),
                diffs: model.showsDiff
            ) { [weak self] action in
                self?.card.close()
                switch action {
                case .open:
                    if node.kind == .file {
                        self?.model.open(place, diff: false)
                    } else {
                        self?.model.open(outside: place)
                    }
                case .diff: self?.model.open(place, diff: true)
                }
            }
            card.show(content, relativeTo: rect, of: tree, edge: .maxY)
        }
    }

    private func zoom(by factor: CGFloat) {
        scroll.animator().magnification = min(
            scroll.maxMagnification, max(scroll.minMagnification, scroll.magnification * factor))
    }

    /// Shrinks the tree to the room, down to where its words still read, and shows the agent at the left: a turn
    /// too big to fit opens where it starts, not at its first folder's corner.
    private func fit(animated: Bool) {
        let size = tree.frame.size, room = scroll.contentSize
        guard size.width > 0, size.height > 0 else { return }
        let readable: CGFloat = 0.6
        let scale = min(1, max(readable, min(room.width / size.width, room.height / size.height)))
        (animated ? scroll.animator() : scroll).magnification = scale
        guard let agent = tree.rect(of: "agent") else { return }
        let visible = scroll.contentView.bounds.size
        let y = min(max(0, agent.midY - visible.height / 2), max(0, size.height - visible.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
