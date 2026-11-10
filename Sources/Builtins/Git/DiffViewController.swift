import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

final class DiffTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

/// Diffs the way VS Code shows them: side by side (or inline), whole-line red / green, the changed words darker,
/// hatching where one side has no line. One file (from Source Control) or every change with review comments for the agent.
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
    /// Whitespace-only changes left out: what's shown is then no patch git can stage or discard as it is.
    var hidesSpace: Bool { spaceToggle.isSelected(forSegment: 0) }
    var find = DiffFinding()
    /// The files marked as read (`DiffViewed`).
    var viewed = ViewedMarks()
    /// Unchanged lines the user opened between changes, by `DiffRows.gapKey` (`DiffGaps`).
    var opened: [String: [DiffLine]] = [:]
    /// The session reviewing this diff, if one was started here (`DiffReviewWith`).
    var reviewer: String?
    let reviewPop = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The agent's turns, with "Agent's Last Turn" (`DiffTurns`).
    let turnPop = NSPopUpButton()
    /// The turn picker and Undo Turn…, shown with "Agent's Last Turn" when the agent has turns kept.
    lazy var turnBar = NSStackView(views: [turnPop, undoTurnButton()])
    /// "Change 3 of 17" after a step; a comment's place after a step between comments.
    let position = NSTextField(labelWithString: "")
    private lazy var steps = NSSegmentedControl.steps(
        previous: String(localized: "Previous Change (⌥↑)"), next: String(localized: "Next Change (⌥↓)"),
        target: self, action: #selector(stepped(_:)))
    let files = NSTableView()
    let table = DiffTable()
    let status = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    var diffs: [FileDiff] = []
    /// A line being fixed in place: its field, and what it was (`DiffLineEdit`).
    var lineEdit: (field: NSTextField, path: String, line: Int, text: String)?
    /// A hunk was discarded: what's left fades in rather than the lines jumping up.
    var fadesNextLoad = false
    var rows: [ReviewRow] = []
    var notes = ReviewNotes()
    var changes: [FileChange] = []
    /// Changed character range of a line that has a counterpart on the other side, by "file:kind:line".
    var words: [String: NSRange] = [:]
    /// Each line's tree-sitter captures, by `DiffColors.key`; the theme's colours for them.
    var syntax: [String: [DiffColors.Span]] = [:]
    var syntaxColors = CodeEditor.syntaxColors
    var worktreeId: String?
    var commitHash: String?
    /// One-file mode: (path, what it's read from, commit).
    var single: (file: String, source: DiffSource, commit: String?)?
    /// What the source menu has picked.
    var sourcePicked: DiffSource {
        get { DiffSource(rawValue: source.indexOfSelectedItem) ?? .uncommitted }
        set { source.selectItem(at: newValue.rawValue) }
    }
    /// The editor's font and size, as the code it shows is the editor's; a row is a line of it and 4 pt.
    var font: NSFont { CodeEditor.font }
    static var lineHeight: CGFloat {
        let editorFont = CodeEditor.font
        return (editorFont.ascender - editorFont.descender + editorFont.leading).rounded(.up) + 4
    }
    /// Side by side when chosen and there's room for two columns; a narrow pane shows it inline (like VS Code).
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
        source.lastItem?.toolTip = String(
            localized: "What changed since the agent's last prompt, even with other agents in the same folder")
        source.target = self
        source.action = #selector(sourceChanged)
        status.font = .ui(TextSize.caption)
        status.textColor = .secondaryLabelColor
        position.font = .uiDigits(TextSize.caption)
        position.textColor = .secondaryLabelColor
        position.toolTip = String(localized: "⌥↑ ⌥↓ changes, ⌥⇧↑ ⌥⇧↓ comments")
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fc = NSTableColumn(identifier: .init("file"))
        fc.title = String(localized: "Files")
        files.addTableColumn(fc)
        files.dataSource = self
        files.delegate = self
        files.rowHeight = 26
        files.style = .sourceList
        files.headerView = nil
        fc.resizingMask = .autoresizingMask
        files.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle   // rows as wide as the pane
        files.menu = NSMenu()
        files.menu?.delegate = self
        let fs = NSScrollView()
        fs.documentView = files
        fs.hasVerticalScroller = true
        fs.drawsBackground = false

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
        fs.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        ts.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        self.split = split
        fileList = fs
        buildBar()
        view = stacked(bar, split)
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

    /// The editor's theme or font changed: the code here follows.
    private func themeChanged() {
        table.backgroundColor = CodeEditor.page.background
        table.rowHeight = Self.lineHeight
        syntaxColors = CodeEditor.syntaxColors
        rebuildRows()
    }

    private let bar = Bar.content([])
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
            func btn(_ title: String, _ action: Selector) -> NSButton {   // sized by the bar, as its pop-ups
                let button = NSButton(title: title, target: self, action: action)
                button.bezelStyle = .push
                return button
            }
            bar.set(
                [
                    source, turnBar, layoutToggle, spaceToggle,
                    btn(String(localized: "Comment"), #selector(addComment)), reviewPop,
                    btn(String(localized: "Send to Agent"), #selector(sendComments))
                ], [status, position, steps])
        }
    }

    @objc private func stepped(_ s: NSSegmentedControl) {
        if s.selectedSegment == 0 { prevChange() } else { nextChange() }
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

    /// Every file of a commit, the same as picking it under Commit…
    func showCommit(_ hash: String) {
        commitHash = hash
        sourcePicked = .commit
    }

    /// One file, VS Code's diff editor: no file list, just this file's changes.
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
                    attributes: [.font: NSFont.ui(TextSize.caption), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        pathLabel.attributedStringValue = pathText
        buildBar()
    }

    @objc func reload() { Task { await load() } }
    /// Git changed while the tab was in the background: it reads the diff again when shown, not on every save meanwhile.
    var stale = false
    override func viewDidAppear() {
        super.viewDidAppear()
        if stale {
            stale = false
            reload()
        }
    }
    /// Its workspace's git as pushed: the diff is read again only when what it's read from changed (`GitDiff.basis`).
    func gitChanged(_ e: GitEvent?) {
        guard diffRequest().basis(e) != loads.basis else { return }
        if view.window == nil { stale = true } else { reload() }
    }
    func showLastTurn() { sourcePicked = .turn }
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

    /// The order reads and row builds come in (`DiffLoads`).
    var loads = DiffLoads()

}

/// What a review's diff is read from: the source menu's items in their order, each with the name the daemon knows it by
/// (`GitDiff.source`, a diff tab's `source=`).
enum DiffSource: Int, CaseIterable {
    case uncommitted, unstaged, staged, branch, commit, turn

    var wire: String {
        switch self {
        case .uncommitted: "all"
        case .unstaged: "unstaged"
        case .staged: "staged"
        case .branch: "branch"
        case .commit: "commit"
        case .turn: "turn"
        }
    }

    init?(wire: String) {
        guard let found = Self.allCases.first(where: { $0.wire == wire }) else { return nil }
        self = found
    }

    var title: String {
        switch self {
        case .uncommitted: String(localized: "Uncommitted")
        case .unstaged: String(localized: "Unstaged")
        case .staged: String(localized: "Staged")
        case .branch: String(localized: "Branch vs base")
        case .commit: String(localized: "Commit…")
        case .turn: String(localized: "Agent's Last Turn")
        }
    }

    /// The working tree's own changes, against the index or HEAD: what can be staged, unstaged or discarded.
    var isLive: Bool { self == .uncommitted || self == .unstaged || self == .staged }
}
