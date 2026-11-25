import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// Source Control, modeled on VS Code's: branch and sync up top, the commit message, the merge, staged and unstaged
/// changes (a click shows the diff), and the history graph. All git work happens in the daemon; this only lays out
/// the answers.
@MainActor
final class SourceControlController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    enum Section: String {
        case merge = "Merge Changes", staged = "Staged Changes", changes = "Changes", graph = "Graph"
    }

    /// A row, kept across rebuilds by its key (a section, a path, a hash), so the outline keeps its place and its cell.
    final class Node: NSObject {
        enum Kind {
            case section(Section), file(FileChange, Section), commit(Int), commitFile(String, FileChange), note(String)
        }
        /// What a file's or a commit's row shows. A rebuild draws again only the rows whose look changed.
        enum Look: Equatable {
            case file(FileChange, shared: [String], commit: Int?)
            case commit(GraphCommit, head: Bool, pushed: Bool?, lands: Double?, arrives: Double?)
            case commitFile(FileChange, lanes: [Int])
        }
        var kind: Kind
        var look: Look?
        var children: [Node] = []
        var files: [FileChange] = []   // the section's files, kept while it is folded too
        init(_ k: Kind) { kind = k }
    }
    /// The rows of the last rebuild, by key (`Node`).
    var changeNodes: [String: Node] = [:], graphNodes: [String: Node] = [:]
    /// What each workspace showed when another one came on screen. Switching back shows it at once, and git is read
    /// again only where the status the daemon pushes says it changed (`apply`). `info` is what the graph was read for.
    var seen: [String: Seen] = [:]
    struct Seen {
        var changes: [FileChange], info: BranchInfo?, commits: [GraphCommit], unpushed: Set<String>, more: Bool,
            limit: Int
    }
    /// The branches the graph on show was read for.
    var graphInfo: BranchInfo?

    let outline = NSOutlineView()
    let graphOutline = GraphOutline()
    let graphBar = GraphBar()
    var graphHeight: NSLayoutConstraint?, graphClosed: NSLayoutConstraint?, barHeight: NSLayoutConstraint?
    /// Until the user drags the divider, the changes are as tall as their rows, up to half the panel, and the open
    /// graph follows right under them, because a gap there looked like something still loading. The changes keep at
    /// least their rows' height, up to 80 pt.
    var changesHug: NSLayoutConstraint?, changesCap: NSLayoutConstraint?, changesRoom: NSLayoutConstraint?
    /// How tall the changes' rows are, for `fitChanges`.
    var changesRows: CGFloat = 0
    /// How many of `fitChanges`'s moves are under way: each step of one lays the panel out again.
    var changesMoving = 0
    let branchButton = BranchChip()   // greys in under the pointer, as the window bar's branch chip does
    lazy var bar = SourceControlBar(self)
    let message = CommitTextView()
    let placeholder = NSTextField(labelWithString: "")
    var messageField: NSView?, messageScroll: NSView?
    private var messageHeight: NSLayoutConstraint?
    var commitButton: SplitPushButton?
    /// The menus beside Commit: its other ways (Commit & Push, Amend), or Push / Pull while it offers to sync.
    private let commitMenu = NSMenu(), syncMenu = NSMenu(), planMenu = NSMenu()
    private var moreMenu: NSMenu?
    private var pullItem: NSMenuItem?
    var moreButton: NSButton?
    var commitArea: NSView?, separator: NSView?
    let empty = EmptyStateView()
    let loading = LoadingView(rows: true, rowHeight: Metrics.row)
    private(set) lazy var failureBar = FailureBar { [weak self] in self?.reloadAll() }
    var headerBar: NSView?

    var worktreeId: String?
    var changes: [FileChange] = []
    /// The files that another folder of the project changes too, with that folder's branches.
    var shared: [String: [String]] = [:]
    var info: BranchInfo?
    var commits: [GraphCommit] = []
    var unpushed = Set<String>()
    /// Commits that just reached the remote, and when each one lands, oldest first as they left.
    var landing: [String: Double] = [:]
    /// Commits just made or pulled, which come into the graph one after another (hash: when).
    var arriving: [String: Double] = [:]
    /// What the panel's button says it just did, for a moment afterwards.
    var confirmed: String?
    /// Counts the calls to `finish`, so a later one, or new work, takes over the moment of the one on show.
    var finishes = 0
    /// True after a commit went through, so the list of changes fades to what's left rather than switching.
    var clearing = false
    /// Files that were staged, unstaged or discarded. Their rows travel to their places when the status shows the
    /// change (the shape then).
    var staging: Set<String>?
    /// How many actions that stay here (stage, commit) run, by workspace. An action outlives a switch to another
    /// workspace and ends on its own. A pull, push or fetch belongs to `SyncState`.
    var work: [String: Int] = [:]
    /// Commit messages being written in the workspaces not on screen.
    var drafts: [String: String] = [:]
    /// By workspace: the agent writing the commit (AgentCommit.swift), the commits it proposed, and the words it left.
    var agentCommits: [String: AgentCommit] = [:]
    var plans: [String: CommitPlan] = [:]
    var notes: [String: AgentNote] = [:]
    lazy var agentUI = AgentCommitControls(self)
    /// The pull, push or fetch running on the branch, whoever started it: what the button says, and whether the ↑ and
    /// ↓ arrows pulse.
    var syncing: (title: String, push: Bool, pull: Bool)? {
        worktreeId.flatMap { GitSync.state(app).running[$0] }.map { ($0.title, $0.op == .push, $0.op == .pull) }
    }
    var busy: Bool { worktreeId.flatMap { work[$0] } != nil || syncing != nil }
    var more = false, limit = 200, loadingMore = false
    var commitFiles: [String: [FileChange]] = [:]
    var openCommits = Set<String>()
    /// The card for the commit under the pointer, with the daemon's details. They are read quietly, and without them
    /// the card shows what the row has.
    lazy var card: CommitCard = {
        let commitCard = CommitCard()
        commitCard.load = { [weak self] hash in
            guard let self, let wid = self.worktreeId else { return nil }
            return await self.app.quiet(GitCommitDetails(id: wid, commit: hash))
        }
        commitCard.picture = { [weak self] email in
            guard let self, let wid = self.worktreeId,
                let data = await self.app.quiet(GitAuthorAvatar(id: wid, email: email)) ?? nil
            else { return nil }
            return NSImage(data: data)
        }
        commitCard.onAction = { [weak self] in self?.cardAction($0, $1) }
        commitCard.menu = { [weak self] commit in
            let menu = NSMenu()
            self?.addCommitItems(commit, to: menu)
            return menu
        }
        return commitCard
    }()
    var collapsed = Set(UserDefaults.standard.stringArray(forKey: "scm.collapsed") ?? [])
    /// The section a click just folded or opened, so the chevron in its rebuilt cell turns.
    var turning: Section?
    var roots: [Node] = []
    var graphRoots: [Node] = []
    /// The workspace's git status and its branch's CI, watched while the panel is on screen (the daemon pushes
    /// changes).
    lazy var gitWatch = Watched(.git, in: app)
    lazy var ciWatch = Watched(.ci, in: app)
    /// Holds what git said while the panel was hidden, and applies it when the panel shows (`apply`).
    lazy var whenShown = WhenShown(view)
    let stats = NSTextField(labelWithString: "")
    let ciRow = CIStatusRow()
    var ciRuns: [CIRuns.Run] = []
    /// Where each failed run broke ("job › step"), read once, because a finished run doesn't change.
    var ciFailures: [Int: String] = [:]

    // MARK: view

    /// The lists' room changes with the window and the commit box: the changes fit it again.
    override func viewDidLayout() {
        super.viewDidLayout()
        fitChanges()
    }

    override func loadView() {
        let app = self.app
        branchButton.target = self
        branchButton.action = #selector(branchMenu)
        branchButton.toolTip = String(localized: "Switch or create a branch")
        branchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        moreButton = bar.more
        stats.font = .uiDigits(TextSize.micro, weight: .medium)
        let header = failureBar.under(bar.header(branchButton))
        headerBar = header

        let box = commitBox()
        commitArea = box
        let scroll = list(outline), graphScroll = list(graphOutline)
        followGraphKeys()
        graphBar.onToggle = { [weak self] in self?.toggle(.graph) }
        graphBar.onResize = { [weak self] in self?.resizeGraph(by: $0) }
        graphBar.onRefresh = { [weak self] in Task { await self?.refreshGraph() } }

        let root = NSView()
        let sep = NSBox()
        sep.boxType = .separator
        separator = sep
        for part in [header, box, sep, scroll, graphBar, graphScroll] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(part)
        }
        // When open, the graph is at least the height it was dragged to, and takes what the changes leave: a short list
        // of changes is followed by the graph, not by empty room. It gives way to the changes and, under
        // windowSizeStayPut, to the window's size: held above it, less room for the lists (a CI strip coming in) grew a
        // floating inspector past the window's top, and the window bar and the panels' tops went with it.
        let gh = graphScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        gh.priority = .init(490)
        graphHeight = gh
        // Set in numbers (`fitChanges`), above windowSizeStayPut: a wish weaker than the window's keeping its parts'
        // sizes lost to it, and the list kept an old, tall height over two changes.
        changesHug = scroll.heightAnchor.constraint(equalToConstant: 0)
        changesHug?.priority = .init(750)
        changesCap = scroll.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, multiplier: 0.5)
        changesCap?.priority = .init(750)   // weaker than the 80 pt the changes keep
        graphClosed = graphScroll.heightAnchor.constraint(equalToConstant: 0)
        graphClosed?.priority = .defaultHigh
        let bh = graphBar.heightAnchor.constraint(equalToConstant: 0)
        barHeight = bh
        let room = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        room.priority = .init(760)   // the changes keep 80 pt, so the graph shrinks first
        changesRoom = room
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            box.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            box.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Unset, a rebuilt panel's layout can stretch the line tall (and vertical).
            sep.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: graphBar.topAnchor), room,
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            graphBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            graphBar.trailingAnchor.constraint(equalTo: root.trailingAnchor), bh,
            graphScroll.topAnchor.constraint(equalTo: graphBar.bottomAnchor),
            graphScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            graphScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            graphScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        empty.place(in: root, under: header)
        loading.place(in: root, under: sep)   // where the changes will be: the commit box stays as it is
        view = root
        updateHeader()   // so NSButton's own "Button" title doesn't show while the branch loads
        if app.workbench.workspaceId == nil { showNoProject(true) }
        followAgentCommits()
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] in
            self?.bind($0)
        }
        track(owner: self) { [weak self, app] in
            app.latest(GitEvent.self, self?.gitKey ?? "")
        } changed: { [weak self] event in
            self?.whenShown.run { self?.apply(event) }
        }
        track(owner: self) { [weak self, app] in
            app.sharedFiles(self?.gitKey)
        } changed: { [weak self] in
            self?.shared = $0
            self?.rebuildChanges()
        }
        track(owner: self) { [weak self, app] in
            app.latest(CIEvent.self, self?.gitKey ?? "")
        } changed: { [weak self] in
            self?.applyCI($0)
        }
        track(owner: self, now: false) { [weak self] in
            self?.gitKey
        } changed: { [weak self] _ in
            self?.followWatches()   // the folder's workspace went, so the watch follows the one it shares now
        }
        track(owner: self, now: false) { [weak self, app] in
            self?.worktreeId.flatMap { GitSync.state(app).running[$0] }
        } changed: { [weak self] _ in
            self?.showWork()
        }
        track(owner: self) {
            app.fileIcons.revision
        } changed: { [weak self] _ in
            for outlineView in [self?.outline, self?.graphOutline].compactMap({ $0 }) {
                outlineView.reloadData(forRowIndexes: IndexSet(0..<outlineView.numberOfRows), columnIndexes: [0])
            }
        }
    }

    /// Makes a list for the panel: one column, no header, and rows drawn by the cells.
    private func list(_ outline: NSOutlineView) -> NSScrollView {
        let scrollView = outline.plainList("scm")
        scrollView.autohidesScrollers = true
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0
        outline.rowSizeStyle = .custom
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        // A file dragged out to Finder or another app is copied there, never moved.
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        return scrollView
    }

    /// The message field (it grows to six lines) and Commit with its split menu.
    private func commitBox() -> NSView {
        // A commit message is written in the editor's font, at its size, as in the Commit Message tab.
        message.plain(font: CodeEditor.font, inset: NSSize(width: 4, height: 6))
        message.drawsBackground = false
        message.isVerticallyResizable = true
        message.autoresizingMask = .width
        message.onCommit = { [weak self] in self?.commit(push: false, amend: false) }
        message.onAgent = { [weak self] in self?.askLastAgent() }
        message.onChange = { [weak self] in self?.messageChanged() }
        let messageScroll = NSScrollView()
        messageScroll.documentView = message
        messageScroll.drawsBackground = false
        messageScroll.hasVerticalScroller = false
        placeholder.textColor = .placeholderTextColor
        placeholder.font = CodeEditor.font
        placeholder.lineBreakMode = .byTruncatingTail
        // A long branch name truncates rather than widening the panel.
        placeholder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let field = FieldBox()
        field.wantsLayer = true
        messageField = field
        self.messageScroll = messageScroll
        commitMenu.add(String(localized: "Commit & Push")) { [weak self] in self?.commit(push: true, amend: false) }
        commitMenu.add(String(localized: "Commit (Amend)")) { [weak self] in self?.commit(push: false, amend: true) }
        syncMenu.add(String(localized: "Push")) { [weak self] in
            self?.remote([.push], done: String(localized: "Pushed"))
        }
        pullItem = syncMenu.add(String(localized: "Pull")) { [weak self] in self?.pullPressed() }
        // The panel's main action, in the accent colour while there's something to commit (macOS 26's primary tint).
        // It has words alone, as macOS's push buttons do, because a ✓ or an arrow before them only crowded the title.
        let cb = SplitPushButton(
            title: String(localized: "Commit"), arrowTip: String(localized: "Commit & Push, Amend…"))
        cb.target = self
        cb.action = #selector(commitPressed)
        cb.toolTip = String(localized: "Commit (⌘↩ in the message)")
        cb.arrow.target = self
        cb.arrow.action = #selector(showCommitMenu)
        commitButton = cb
        let buttons = cb
        cb.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ciRow.onClick = { [weak self] in self?.openCI() }
        let ui = agentUI
        let stack = NSStackView(views: [field, ui.note, ui.plan, buttons, ciRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(4, after: field)   // the words under the field belong to it
        stack.setCustomSpacing(6, after: buttons)   // so a hidden CI line takes no room
        let box = NSView()
        for part in [messageScroll, placeholder, ui.corner, ui.work] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            field.addSubview(part)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        let heightConstraint = messageScroll.heightAnchor.constraint(equalToConstant: 30)
        messageHeight = heightConstraint
        // The agent's logo and chevron sit in the field's top corner. While the agent reads, its line takes the
        // text's place.
        NSLayoutConstraint.activate([
            messageScroll.topAnchor.constraint(equalTo: field.topAnchor, constant: 1),
            messageScroll.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -1),
            messageScroll.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            messageScroll.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -2), heightConstraint,
            ui.corner.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -3),
            ui.corner.topAnchor.constraint(equalTo: field.topAnchor, constant: 4),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            ui.work.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 9),
            ui.work.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -4),
            ui.work.topAnchor.constraint(equalTo: field.topAnchor, constant: 5),
            placeholder.leadingAnchor.constraint(equalTo: messageScroll.leadingAnchor, constant: 9),
            placeholder.topAnchor.constraint(equalTo: messageScroll.topAnchor, constant: 7),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: messageScroll.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ui.note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ui.plan.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ciRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return box
    }

    func messageChanged() {
        placeholder.isHidden = !message.string.isEmpty
        if let height = message.fittingHeight(maxLines: 6) { messageHeight?.constant = height }
        updateCommitButton()
    }

    func updateCommitButton() {
        placeholder.stringValue = String(localized: "Message")   // ⌘↩ and what a commit takes are in the tooltip
        guard let cb = commitButton else { return }
        let plan = worktreeId.flatMap { plans[$0] }
        let next = changes.isEmpty && plan == nil ? nextStep : nil
        // What a commit takes: the staged files, or all of them when none are staged.
        let files = changes.filter { $0.staged && !$0.conflicted }.count
        let count = files > 0 ? files : changes.count
        let make = plan.map { String(localized: "Make \($0.commits.count) Commits") }
        cb.say(
            syncing?.title ?? confirmed ?? next ?? make
                ?? (count == 0 ? String(localized: "Commit") : String(localized: "Commit \(count) Files")))
        let moved = syncing == nil && confirmed == nil && next != nil ? syncCounts : []
        cb.counts = moved
        // VoiceOver hears the counts in words: the arrows are pictures now.
        let heard = moved.map {
            $0.symbol == "arrow.down"
                ? String(localized: "\($0.count) to pull") : String(localized: "\($0.count) to push")
        }
        cb.setAccessibilityLabel(heard.isEmpty ? nil : ([next ?? ""] + heard).joined(separator: ", "))
        let idle = next == nil && syncing == nil && confirmed == nil
        moreMenu = plan != nil ? planMenu : next == nil ? commitMenu : syncMenu
        pullItem?.isHidden = info?.upstream == nil
        cb.action = next == nil ? #selector(commitPressed) : #selector(sync)
        let branch = info?.current ?? "HEAD"
        let what =
            files > 0
            ? String(localized: "Commit the staged files on “\(branch)” (⌘↩ in the message)")
            : String(localized: "Commit all changes on “\(branch)” (⌘↩ in the message)")
        cb.toolTip =
            plan != nil
            ? String(localized: "Make the commits one by one, each with only its files (⌘↩ in a card)")
            : next == nil ? what : info?.upstream.map { String(localized: "Pull from and push to \($0)") }
        // While the button says what it's doing or did, it reads as lit, not switched off, and does nothing when
        // pressed.
        let saying = syncing != nil || confirmed != nil
        if saying { cb.action = nil }
        // With no message, Commit opens a page to write one.
        cb.isEnabled = saying || (!busy && (!changes.isEmpty || next != nil))
        // While an agent is still writing the commit, there is nothing to commit yet, so the button is off.
        if worktreeId.map({ agentCommits[$0] != nil }) == true { cb.isEnabled = false }
        cb.arrow.isEnabled = !saying && cb.isEnabled
        bar.update(info, changes: changes.count, busy: busy)
        cb.primary = idle && !changes.isEmpty
        agentUI.corner.alphaValue = busy || changes.isEmpty ? 0.4 : 1   // nothing to write about, or a commit going in
        agentUI.logo.isEnabled = !busy && !changes.isEmpty
    }

    @objc private func showCommitMenu() {
        guard let arrow = commitButton?.arrow else { return }
        if let count = worktreeId.flatMap({ plans[$0] })?.commits.count { fillPlanMenu(count) }
        moreMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: arrow.bounds.height + 4), in: arrow)
    }

    /// The plan's other ways: push after, one commit of it all, or none of it.
    private func fillPlanMenu(_ count: Int) {
        planMenu.removeAllItems()
        planMenu.add(String(localized: "Make \(count) Commits & Push")) { [weak self] in self?.makeCommits(push: true) }
        planMenu.add(String(localized: "Merge Into One Commit")) { [weak self] in self?.editPlan { $0.merge() } }
        planMenu.addItem(.separator())
        planMenu.add(String(localized: "Discard Plan")) { [weak self] in self?.discardPlan() }
    }

    /// With nothing to commit, the button offers what's left, as in VS Code: sync the commits the remote doesn't have
    /// yet (or pull the ones it has), or publish a branch with no upstream.
    private var nextStep: String? {
        guard let info, info.current != nil else { return nil }
        guard info.upstream != nil else { return info.remote.isEmpty ? nil : String(localized: "Publish Branch") }
        let ahead = info.ahead ?? 0, behind = info.behind ?? 0
        return ahead + behind > 0 ? String(localized: "Sync Changes") : nil
    }
    /// What Sync Changes moves, written after the words as the title bar's chip writes it: ↓2 ↑56, to pull first.
    private var syncCounts: [(symbol: String, count: Int)] {
        guard let info, info.upstream != nil else { return [] }
        return [("arrow.down", info.behind ?? 0), ("arrow.up", info.ahead ?? 0)].filter { $0.count > 0 }
    }
}
