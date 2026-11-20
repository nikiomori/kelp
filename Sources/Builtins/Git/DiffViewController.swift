import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

final class DiffTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    /// True when the columns changed width during a live resize, so the rows are measured again once it ends
    /// (`onResized`).
    var resizedLive = false
    var onResized: (() -> Void)?
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard resizedLive else { return }
        resizedLive = false
        onResized?()
    }
}

/// Diffs the way VS Code shows them: side by side (or inline), whole lines red or green, the changed words darker,
/// and hatching where one side has no line. It shows one file (from Source Control), or every change with review
/// comments for the agent.
@MainActor
final class DiffViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    let source = NSPopUpButton()
    private let layoutToggle = NSSegmentedControl(
        images: [
            .symbol("rectangle.split.2x1", String(localized: "Side by Side")),
            .symbol("rectangle", String(localized: "Inline"))
        ],
        trackingMode: .selectOne, target: nil, action: nil)
    private let spaceToggle = NSSegmentedControl(
        images: [.symbol("text.word.spacing", String(localized: "Hide Whitespace Changes"))],
        trackingMode: .selectAny, target: nil, action: nil)
    /// Whether whitespace-only changes are left out. What's shown is then no patch git can stage or discard as it is.
    var hidesSpace: Bool { spaceToggle.isSelected(forSegment: 0) }
    var find = DiffFinding()
    /// The files marked as read (`DiffViewed`).
    var viewed = ViewedMarks()
    /// Unchanged lines the user opened between changes, by `DiffRows.gapKey` (`DiffGaps`).
    var opened: [String: [DiffLine]] = [:]
    /// The session reviewing this diff, if one was started here (`DiffReviewWith`).
    var reviewer: String?
    let reviewPop = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The agent's turns, listed with "Agent’s Last Turn" (`DiffTurns`).
    let turnPop = NSPopUpButton()
    /// The turn picker and Undo Turn…, shown with "Agent’s Last Turn" when the agent has turns kept.
    lazy var turnBar = NSStackView(views: [turnPop, undoTurnButton()])
    /// "Change 3 of 17" after a step between changes, or the comment's place after a step between comments.
    let position = NSTextField(labelWithString: "")
    private lazy var steps = NSSegmentedControl.steps(
        previous: app.extensions.hint(String(localized: "Previous Change"), "git.previousChange"),
        next: app.extensions.hint(String(localized: "Next Change"), "git.nextChange"),
        target: self, action: #selector(stepped(_:)))
    let files = NSTableView()
    let table = DiffTable()
    let status = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    var diffs: [FileDiff] = []
    /// A line being fixed in place: its field, and what the line was (`DiffLineEdit`).
    var lineEdit: (field: NSTextField, path: String, line: Int, text: String)?
    /// True after a hunk was discarded, so what's left fades in rather than the lines jumping up.
    var fadesNextLoad = false
    var rows: [ReviewRow] = []
    /// How many lines each line of code wraps to (`height(of:)`).
    var wraps = WrapCounts()
    var notes = ReviewNotes()
    var changes: [FileChange] = []
    /// The changed character range of each line that has a counterpart on the other side, by "file:kind:line".
    var words: [String: NSRange] = [:]
    /// Each line's tree-sitter captures, by `DiffColors.key`, and the theme's colours for them.
    var syntax: [String: [DiffColors.Span]] = [:]
    var syntaxColors = CodeEditor.syntaxColors
    var worktreeId: String?
    var commitHash: String?
    /// One-file mode: the path, what it's read from, and the commit.
    var single: (file: String, source: DiffSource, commit: String?)?
    /// What the source menu has picked.
    var sourcePicked: DiffSource {
        get { DiffSource(rawValue: source.indexOfSelectedItem) ?? .uncommitted }
        set { source.selectItem(at: newValue.rawValue) }
    }
    /// The editor's font and size, because the code shown is the editor's code. A row is as tall as the editor's line.
    var font: NSFont { CodeEditor.font }
    static var lineHeight: CGFloat {
        let editorFont = CodeEditor.font
        return (editorFont.ascender - editorFont.descender + editorFont.leading).rounded(.up) + CodeEditor.lineExtra
    }
    /// Side by side when chosen and there's room for two columns. A narrow pane shows the diff inline (like VS Code).
    var sideBySide: Bool { layoutToggle.selectedSegment == 0 && !narrow }
    private var narrow = false

    static let hatch = NSColor(
        patternImage: NSImage(size: NSSize(width: 7, height: 7), flipped: false) { _ in
            NSColor.secondaryLabelColor.withAlphaComponent(0.14).setStroke()
            let path = NSBezierPath()
            path.move(to: .zero)
            path.line(to: NSPoint(x: 7, y: 7))
            path.lineWidth = 1
            path.stroke()
            return true
        })

    override func loadView() {
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        layoutToggle.selectedSegment = UserDefaults.standard.bool(forKey: "diff.inline") ? 1 : 0
        layoutToggle.target = self
        layoutToggle.action = #selector(layoutChanged)
        layoutToggle.setToolTip(String(localized: "Side by Side"), forSegment: 0)
        layoutToggle.setToolTip(String(localized: "Inline"), forSegment: 1)
        spaceToggle.setSelected(UserDefaults.standard.bool(forKey: "diff.ignoreSpace"), forSegment: 0)
        spaceToggle.setToolTip(String(localized: "Hide Whitespace Changes"), forSegment: 0)
        spaceToggle.target = self
        spaceToggle.action = #selector(spaceChanged)
        source.addItems(withTitles: DiffSource.allCases.map(\.title))
        source.item(at: DiffSource.tidy.rawValue)?.isHidden = true
        source.item(at: DiffSource.turn.rawValue)?.toolTip = String(
            localized: "What changed since the agent’s last prompt, even with other agents in the same folder")
        source.target = self
        source.action = #selector(sourceChanged)
        status.font = .ui(TextSize.caption)
        status.textColor = .secondaryLabelColor
        position.font = .uiDigits(TextSize.caption)
        position.textColor = .secondaryLabelColor
        position.toolTip = stepsTip
        pathLabel.lineBreakMode = .byTruncatingTail   // name, then folder: the folder is cut first
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fs = files.plainList("file")
        files.tableColumns.first?.title = String(localized: "Files")
        files.dataSource = self
        files.delegate = self
        files.rowHeight = TextSize.of(Metrics.row)
        files.style = .sourceList
        files.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle   // rows are as wide as the pane
        files.menu = NSMenu()
        files.menu?.delegate = self

        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.lineHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.allowsMultipleSelection = true
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = CodeEditor.page.background
        table.floatsGroupRows = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnsResized), name: NSTableView.columnDidResizeNotification, object: table)
        table.onKey = { [weak self] e in self?.key(e) ?? false }
        table.onResized = { [weak self] in self?.remeasure() }
        table.menu = NSMenu()
        table.menu?.delegate = self
        let ts = NSScrollView()
        ts.documentView = table
        ts.hasVerticalScroller = true
        ts.autohidesScrollers = true
        setColumns()

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(fs)
        split.addArrangedSubview(ts)
        // These widths are wished for, not required, so in a pane narrower than both the diff is narrower, not cut
        // at its right.
        for (pane, least) in [(fs, 160.0), (ts, 300.0)] {
            let room = pane.widthAnchor.constraint(greaterThanOrEqualToConstant: least)
            room.priority = .init(999)
            room.isActive = true
        }
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        self.split = split
        fileList = fs
        buildBar()
        view = stacked(failureBar.under(bar), split)
        empty.place(in: view, under: bar)
        loading.place(in: view, under: bar)
        track(owner: self) { [app] in
            app.themes.editorRevision
        } changed: { [weak self] _ in
            self?.themeChanged()
        }
        track(owner: self) { [app] in
            app.workbench.panelBeside
        } changed: { [weak self] _ in
            self?.placeFileList()
        }
        Self.reviews.add(self)
        turnBar.isHidden = true
        turnPop.target = self
        turnPop.action = #selector(sourceChanged)
        reviewPop.addItem(withTitle: String(localized: "Review with"))
        reviewPop.menu?.delegate = self
        followReviewer()
    }

    /// Called when the editor's theme or font changed, so the code here follows.
    private func themeChanged() {
        table.backgroundColor = CodeEditor.page.background
        table.rowHeight = Self.lineHeight
        wraps = WrapCounts()   // another font wraps at other places
        syntaxColors = CodeEditor.syntaxColors
        rebuildRows()
    }

    private let bar = Bar.content([])
    /// Where the diff stands while it's on its way, when there is none, or when git couldn't read it (`showState`).
    let empty = EmptyStateView(), loading = LoadingView()
    lazy var tryAgain = ClosureButton(title: String(localized: "Try Again")) { [weak self] in self?.reload() }
    /// Says over the diff on screen that reading it again failed, which keeps it (`loadOnce`).
    lazy var failureBar = FailureBar { [weak self] in self?.reload() }
    var split: NSSplitView?
    var fileList: NSView?
    var positioned = false
    override func viewDidLayout() {
        super.viewDidLayout()
        placeFileList()
        if !positioned, fileList?.isHidden == false, let split, split.bounds.width > 400 {
            positioned = true
            split.setPosition(220, ofDividerAt: 0)
        }
        let nowNarrow = table.bounds.width > 0 && table.bounds.width < 640
        if nowNarrow != narrow {
            narrow = nowNarrow
            layoutToggle.setEnabled(!nowNarrow, forSegment: 0)
            layoutToggle.setToolTip(
                nowNarrow ? String(localized: "Side by Side (needs a wider pane)") : String(localized: "Side by Side"),
                forSegment: 0)
            setColumns()
            rebuildRows()
        }
    }

    private func buildBar() {
        if single != nil {
            bar.set([pathLabel, status], [position, steps, spaceToggle, layoutToggle])
        } else {
            func btn(_ title: String, _ action: Selector) -> NSButton {
                TextButton(title, target: self, action: action)
            }
            bar.set(
                [
                    source, turnBar, layoutToggle, spaceToggle,
                    btn(String(localized: "Comment"), #selector(addComment)), reviewPop,
                    btn(String(localized: "Send to Agent"), #selector(sendComments))
                ], [status, position, steps])
        }
    }

    @objc private func stepped(_ segmentedControl: NSSegmentedControl) {
        if segmentedControl.selectedSegment == 0 { prevChange() } else { nextChange() }
    }

    private func setColumns() {
        table.tableColumns.forEach(table.removeTableColumn)
        for id in sideBySide ? ["on", "l", "nn", "r"] : ["on", "nn", "t"] {
            let column = NSTableColumn(identifier: .init(id))
            if id == "on" || id == "nn" {
                column.width = 44
                column.resizingMask = []
            } else {
                column.width = 400
                column.minWidth = 120
                column.resizingMask = .autoresizingMask
            }
            table.addTableColumn(column)
        }
        table.sizeToFit()
    }

    func show(worktree id: String?) {
        worktreeId = id
        loads.asking += 1
        Task { await load() }
    }

    /// Shows every file of a commit, the same as picking the commit under Commit…
    func showCommit(_ hash: String) {
        commitHash = hash
        sourcePicked = .commit
    }

    /// Shows one file, like VS Code's diff editor: no file list, just this file's changes.
    func showFile(_ path: String, source: DiffSource, commit: String?) {
        single = (path, source, commit)
        placeFileList()
        let dir = (path as NSString).deletingLastPathComponent
        let pathText = NSMutableAttributedString(
            string: (path as NSString).lastPathComponent, attributes: [.font: NSFont.ui(TextSize.row, weight: .medium)])
        if !dir.isEmpty {
            pathText.append(
                NSAttributedString(
                    string: "  " + dir,
                    attributes: [.font: NSFont.ui(TextSize.caption), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        pathLabel.attributedStringValue = pathText
        buildBar()
    }

    @objc func reload() { Task { await load() } }
    /// True when git changed while the tab was in the background. The diff is read again when the tab shows, not on
    /// every save meanwhile.
    var stale = false
    override func viewDidAppear() {
        super.viewDidAppear()
        if stale {
            stale = false
            reload()
        }
    }
    /// Takes the workspace's git status as pushed. The diff is read again only when what it's read from changed
    /// (`GitDiff.basis`).
    func gitChanged(_ gitEvent: GitEvent?) {
        guard diffRequest().basis(gitEvent) != loads.basis else { return }
        if view.window == nil { stale = true } else { reload() }
    }
    func showLastTurn() { sourcePicked = .turn }
    /// Tidy Up's review. Its item in the source menu is hidden otherwise, and shows while it's picked.
    func showTidy() {
        source.item(at: DiffSource.tidy.rawValue)?.isHidden = false
        sourcePicked = .tidy
    }
    @objc private func sourceChanged() {
        askCommit = sourcePicked == .commit
        loads.asking += 1
        reload()
    }
    var askCommit = false
    @objc private func layoutChanged() {
        UserDefaults.standard.set(!sideBySide, forKey: "diff.inline")
        setColumns()
        rebuildRows()
    }

    @objc private func spaceChanged() {
        UserDefaults.standard.set(hidesSpace, forKey: "diff.ignoreSpace")
        loads.asking += 1
        reload()
    }

    /// Keeps the order that reads and row builds come in (`DiffLoads`).
    var loads = DiffLoads()

}

/// What a review's diff is read from. These are the source menu's items in their order, each with the name the daemon
/// knows it by (`GitDiff.source`, a diff tab's `source=`).
enum DiffSource: Int, CaseIterable {
    case uncommitted, unstaged, staged, branch, commit, turn
    /// Tidy Up's copies of the instruction files against the files now (Skills & MCP › Review). It shows only in a
    /// tab opened for it, not in the menu.
    case tidy

    var wire: GitDiff.Source {
        switch self {
        case .uncommitted: .all
        case .unstaged: .unstaged
        case .staged: .staged
        case .branch: .branch
        case .commit: .commit
        case .turn: .turn
        case .tidy: .tidy
        }
    }

    init?(wire: GitDiff.Source) {
        guard let found = Self.allCases.first(where: { $0.wire == wire }) else { return nil }
        self = found
    }

    var title: String {
        switch self {
        case .uncommitted: String(localized: "Uncommitted")
        case .unstaged: String(localized: "Unstaged")
        case .staged: String(localized: "Staged")
        case .branch: String(localized: "Branch vs Base")
        case .commit: String(localized: "Commit…")
        case .turn: String(localized: "Agent’s Last Turn")
        case .tidy: String(localized: "Before Tidy Up")
        }
    }

    /// The working tree's own changes, against the index or HEAD, which are what can be staged, unstaged or discarded.
    var isLive: Bool { self == .uncommitted || self == .unstaged || self == .staged }
}
