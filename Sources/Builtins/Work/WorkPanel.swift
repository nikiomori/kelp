import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The inspector's Work panel: where the agent in focus worked. Steps shows its turn step by step, as the commit graph
/// shows commits (agents as lanes); Places shows its project in layers (folders over files, as wide as the files
/// touched), the places outside the project as chips, and the files of the block picked. The bar names the agent, picks
/// the turn and opens the Map tab. It reads only while it is on screen.
@MainActor
final class WorkPanel: NSViewController {
    let app: AppModel
    let model: WorkModel
    private let face = NSImageView()
    private let name = NSTextField.label("", font: .ui(TextSize.row, weight: .medium))
    private let turnPop = NSPopUpButton()
    private lazy var openTab = IconButton(
        .symbol("map"), tip: String(localized: "Open Map"), target: self,
        action: #selector(openAsTab))
    private let summary = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    private lazy var views = CapsuleSegments(
        labels: [String(localized: "Steps"), String(localized: "Places")], target: self, action: #selector(switchView))
    private let agents = AgentPicker()
    let icicle = IcicleView()
    let chips = OutsideChips()
    private let heading = NSTextField.label(
        "", font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
    private lazy var back = TextButton(String(localized: "Back"), target: self, action: #selector(zoomOut))
    let files = WorkFileList()
    let steps = StepsList()
    private let mapColumn = NSStackView(), stepsColumn = NSStackView()
    private var controlRows: [NSView] = []
    private let empty = EmptyStateView()
    /// While a long conversation is read the first time (a 50 MB transcript takes a few seconds).
    private let loading = LoadingView(rows: true)
    private var watched: Watched?
    private var shown = false
    /// The block the layers start from (its path), and the one picked under it.
    var zoom = "", picked: String?

    init(app: AppModel, choices: WorkChoices) {
        self.app = app
        model = WorkModel(app: app, choices: choices)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        face.imageScaling = .scaleProportionallyDown
        face.widthAnchor.constraint(equalToConstant: Metrics.appIcon).isActive = true
        turnPop.controlSize = .small
        turnPop.font = .ui(TextSize.caption)
        turnPop.target = self
        turnPop.action = #selector(pickTurn)
        let header = Bar.panel([face, name], [turnPop, openTab])
        views.controlSize = .small
        views.selectedSegment = 1
        agents.onPick = { [weak self] in self?.model.picked = $0 }
        turnPop.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        turnPop.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.formLabel + 2 * Metrics.blockGap).isActive =
            true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // the name gives way first
        let controls = NSStackView(views: [views, agents])
        controls.spacing = Metrics.gap
        controls.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        summary.lineBreakMode = .byTruncatingTail
        let summaryRow = NSStackView(views: [summary])
        summaryRow.edgeInsets = NSEdgeInsets(
            top: Metrics.gapTight, left: Metrics.inset, bottom: 0, right: Metrics.inset)

        icicle.onSelect = { [weak self] in self?.pick($0) }
        icicle.onZoom = { [weak self] in $0.map { self?.zoom(to: $0) } ?? self?.zoomOut() }
        icicle.onOpen = { [weak self] path in
            guard let self, let place = model.work?.places.first(where: { $0.kind == .file && $0.name == path }) else {
                return
            }
            model.open(place, diff: NSEvent.modifierFlags.contains(.option))
        }
        chips.onOpen = { [weak self] in self?.model.open(outside: $0) }
        chips.opens = { [weak self] in self?.model.opens($0) ?? false }
        files.onOpen = { [weak self] place, diff in self?.model.open(place, diff: diff) }
        steps.onOpen = { [weak self] in self?.model.open(step: $0) }
        let headingRow = NSStackView(views: [heading, NSView(), back])
        headingRow.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.rowSection)).isActive = true
        headingRow.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.insetTrailing)
        headingRow.alignment = .lastBaseline
        back.font = .ui(TextSize.caption)
        let icicleRow = NSStackView(views: [icicle])
        icicleRow.edgeInsets = NSEdgeInsets(top: Metrics.gapWide, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        let chipsRow = NSStackView(views: [chips])
        chipsRow.edgeInsets = NSEdgeInsets(top: Metrics.gapWide, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        for (column, parts) in [
            (mapColumn, [icicleRow, chipsRow, headingRow, files.scroll]), (stepsColumn, [steps.scroll])
        ] {
            column.orientation = .vertical
            column.spacing = 0
            column.setViews(parts, in: .top)
            for part in parts { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        }
        icicle.widthAnchor.constraint(equalTo: icicleRow.widthAnchor, constant: -2 * Metrics.inset).isActive = true
        chips.widthAnchor.constraint(equalTo: chipsRow.widthAnchor, constant: -2 * Metrics.inset).isActive = true
        stepsColumn.isHidden = true
        controlRows = [summaryRow, controls]
        // The bar and the rows under it keep their height: the map or the steps below take the rest.
        header.setContentHuggingPriority(.defaultHigh, for: .vertical)
        for row in [summaryRow, controls, icicleRow, chipsRow, headingRow] {
            row.setHuggingPriority(.defaultHigh, for: .vertical)
        }
        let column = NSStackView(views: [header, summaryRow, controls, mapColumn, stepsColumn])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
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
        // Another agent in focus, a turn chosen, or a conversation that grew: read again.
        track(owner: self) { [weak self] in
            self?.focused?.id
        } changed: { [weak self] in
            self?.follow($0)
        }
        track(owner: self) { [weak self] in
            guard let self else { return Values(String?.none, Int?.none, false) }
            let stamp = model.session.flatMap { app.latest(WorkEvent.self, $0)?.stamp }
            return Values(stamp, model.turn, model.whole)
        } changed: { [weak self] _ in
            self?.reload()
        }
        track(owner: self) { [weak self] in
            Values(
                self?.model.work, self?.model.picked, self?.model.error,
                self?.model.session.flatMap { self?.app.session($0)?.status })
        } changed: {
            [weak self] _ in
            self?.render()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        shown = true
        watched?.key = model.session
        reload()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        shown = false
        watched?.key = nil
    }

    /// The agent whose Map tab has focus, else the agent chat looked at last in the workspace on screen, else its
    /// newest agent chat (one that hasn't exited first).
    private var focused: Session? {
        let workspace = app.workbench.workspaceId
        if let tab = app.workbench.focusedTab, TabURI.scheme(tab) == WorkTab.scheme,
            let shown = app.session(TabURI.body(tab))
        {
            return shown
        }
        if let last = app.workbench.lastSession.flatMap(app.session), last.worktreeId == workspace, last.isAgent {
            return last
        }
        let chats = app.sessions.filter { $0.worktreeId == workspace && $0.isChat && $0.isAgent }
        return chats.last { $0.status != .exited } ?? chats.last
    }

    private func follow(_ id: String?) {
        model.show(id)
        zoom = ""
        picked = nil
        if shown { watched?.key = id }
        let session = id.flatMap(app.session)
        face.image = session.flatMap { app.catalog.icon($0.agent, size: Metrics.appIcon) }
        name.stringValue = session.map(app.catalog.displayName) ?? ""
        reload()
    }

    private func reload() {
        guard shown else { return }
        model.load()
    }

    // MARK: Showing

    private func render() {
        guard isViewLoaded else { return }
        let work = model.work
        fillTurns(work)
        if model.session == nil || model.error != nil && work == nil { loading.show(nil) }
        if model.session == nil {
            return showEmpty(
                String(localized: "No Agent"), text: String(localized: "Open an agent's chat to see where it worked."))
        }
        if let error = model.error, work == nil {
            empty.showError(String(localized: "Couldn’t read where the agent worked"), text: error)
            return hideColumns()
        }
        loading.show(work == nil && !model.loaded ? String(localized: "Reading where the agent worked…") : nil)
        guard let work else {
            return model.loaded
                ? showEmpty(
                    String(localized: "No Transcript to Read"),
                    text: String(
                        localized: "This agent keeps no transcript Kelp can read, or its host isn’t connected."))
                : hideColumns()
        }
        if work.places.isEmpty && work.steps.isEmpty {
            return showEmpty(
                String(localized: "Nothing Touched Yet"),
                text: String(localized: "Files and places show up here as the agent works."))
        }
        empty.show(nil)
        controlRows.forEach { $0.isHidden = false }
        agents.show(AgentPicker.entries(work, names: model.agentNames), picked: model.picked)
        summary.stringValue =
            WorkSummary.now(work, working: work.now != nil, names: model.agentNames)
            ?? WorkSummary.line(work, turn: work.turn)
        let tree = WorkTree.project(work, rootName: model.projectName, agents: model.agents)
        // A folder alone under the root ("Kelp" over "Sources") says nothing as a row of its own: start below it.
        var shownRoot = tree.node(at: zoom) ?? tree
        while shownRoot.children.count == 1, let only = shownRoot.children.first, !only.isFile, !shownRoot.searched {
            shownRoot = only
        }
        let noFiles = tree.children.isEmpty
        icicle.superview?.isHidden = noFiles
        files.scroll.isHidden = noFiles
        icicle.agentNames = model.agentNames
        icicle.root = shownRoot
        icicle.now = work.now.flatMap { work.places.indices.contains($0) ? work.places[$0] : nil }.map(\.name)
        let pickedNode = picked.flatMap(shownRoot.node(at:)) ?? shownRoot
        icicle.selected = picked == nil ? nil : pickedNode.path
        heading.stringValue =
            noFiles
            ? String(localized: "No project files in this turn")
            : pickedNode.path.isEmpty ? String(localized: "In the project") : pickedNode.path
        back.isHidden = zoom.isEmpty
        files.show(pickedNode, names: model.agentNames, app: app, agents: work.agents)
        chips.show(WorkTree.outside(work, agents: model.agents))
        steps.show(work, names: model.agentNames, app: app, filter: model.agents)
        views.setEnabled(!model.whole, forSegment: 0)
        let stepsOn = views.selectedSegment == 0 && !model.whole
        mapColumn.isHidden = stepsOn
        stepsColumn.isHidden = !stepsOn
    }

    private func showEmpty(_ title: String, text: String) {
        empty.show(title, symbol: "map", text: text)
        hideColumns()
    }

    private func hideColumns() {
        mapColumn.isHidden = true
        stepsColumn.isHidden = true
        controlRows.forEach { $0.isHidden = true }
    }

    private func fillTurns(_ work: AgentWork?) { TurnMenu.fill(turnPop, work: work, model: model) }

    // MARK: Actions

    @objc private func pickTurn() {
        TurnMenu.pick(turnPop, model: model)
        picked = nil
        zoom = ""
    }

    @objc private func switchView() { render() }

    @objc private func openAsTab() {
        guard let session = model.session, let workspace = app.session(session)?.worktreeId else { return }
        _ = app.workbench.openBeside(WorkTab.uri(session), in: workspace)
    }

    func pick(_ path: String) {
        picked = path
        render()
    }

    func zoom(to path: String) {
        zoom = path
        picked = path
        render()
    }

    @objc func zoomOut() {
        guard !zoom.isEmpty else { return }
        let parent = (zoom as NSString).deletingLastPathComponent
        let tree = model.work.map { WorkTree.project($0, rootName: model.projectName, agents: model.agents) }
        // A merged folder chain ("Daemon/Sessions") is one node: step out past the whole chain.
        var up = parent
        while !up.isEmpty, tree?.node(at: up) == nil { up = (up as NSString).deletingLastPathComponent }
        picked = zoom
        zoom = up
        render()
    }
}
