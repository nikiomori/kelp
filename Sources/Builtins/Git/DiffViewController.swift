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
    /// Files marked as read, with their diff's print then (`DiffViewed`).
    var viewed: [String: String] = [:]
    /// Each file's print (`ViewedFiles.print`), made with its rows off the main thread: a big diff hashes slowly.
    var prints: [String: String] = [:]
    /// The last write of `viewed`: each waits for the one before, so quick clicks land in order.
    var viewedWrite: Task<Void, Never>?
    /// Unchanged lines the user opened between changes, by `DiffRows.gapKey` (`DiffGaps`).
    var opened: [String: [DiffLine]] = [:]
    /// The comment being written, if any (`DiffDraft`).
    var draft: CommentDraft?
    /// Open comments left out of Send to Agent (`DiffFindings`).
    var skipped: Set<String> = []
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
    var comments: [DiffComment] = []
    var changes: [FileChange] = []
    /// Changed character range of a line that has a counterpart on the other side, by "file:kind:line".
    var words: [String: NSRange] = [:]
    /// Each line's tree-sitter captures, by `DiffColors.key`; the theme's colours for them.
    var syntax: [String: [DiffColors.Span]] = [:]
    var syntaxColors = CodeEditor.syntaxColors
    var worktreeId: String?
    var commitHash: String?
    /// One-file mode: (path, "unstaged" | "staged", commit).
    var single: (file: String, source: String, commit: String?)?
    /// The editor's font and size, as the code it shows is the editor's; a row is a line of it and 4 pt.
    var font: NSFont { CodeEditor.font }
    static var lineHeight: CGFloat {
        let editorFont = CodeEditor.font
        return (editorFont.ascender - editorFont.descender + editorFont.leading).rounded(.up) + 4
    }
    /// Side by side when chosen and there's room for two columns; a narrow pane shows it inline (like VS Code).
    private var sideBySide: Bool { layoutToggle.selectedSegment == 0 && !narrow }
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
        source.addItems(withTitles: [
            String(localized: "Uncommitted"), String(localized: "Unstaged"), String(localized: "Staged"),
            String(localized: "Branch vs base"), String(localized: "Commit…"), String(localized: "Agent's Last Turn")
        ])
        source.lastItem?.toolTip = String(
            localized: "What changed since the agent's last prompt, even with other agents in the same folder")
        source.target = self
        source.action = #selector(sourceChanged)
        status.font = .ui(11)
        status.textColor = .secondaryLabelColor
        position.font = .uiDigits(11)
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
    private var split: NSSplitView?
    private var fileList: NSView?
    private var positioned = false
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
        asking += 1
        Task { await load() }
    }

    /// Every file of a commit, the same as picking it under Commit…
    func showCommit(_ hash: String) {
        commitHash = hash
        source.selectItem(at: 4)
    }

    /// One file, VS Code's diff editor: no file list, just this file's changes.
    func showFile(_ path: String, source: String, commit: String?) {
        single = (path, source, commit)
        placeFileList()
        let dir = (path as NSString).deletingLastPathComponent
        let pathText = NSMutableAttributedString(
            string: (path as NSString).lastPathComponent, attributes: [.font: NSFont.ui(12, weight: .medium)])
        if !dir.isEmpty {
            pathText.append(
                NSAttributedString(
                    string: "  " + dir,
                    attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.tertiaryLabelColor]))
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
        guard diffRequest().basis(e) != basis else { return }
        if view.window == nil { stale = true } else { reload() }
    }
    func showLastTurn() { source.selectItem(at: 5) }
    @objc private func sourceChanged() {
        askCommit = source.indexOfSelectedItem == 4
        asking += 1
        reload()
    }
    private var askCommit = false
    @objc private func layoutChanged() {
        UserDefaults.standard.set(!sideBySide, forKey: "diff.inline")
        setColumns()
        rebuildRows()
    }

    @objc private func spaceChanged() {
        UserDefaults.standard.set(hidesSpace, forKey: "diff.ignoreSpace")
        asking += 1
        reload()
    }

    func diffRequest() -> GitDiff {
        var query = request()
        query.ignoreSpace = hidesSpace ? true : nil
        return query
    }
    private func request() -> GitDiff {
        let id = worktreeId ?? ""
        if let single {
            return single.commit.map { GitDiff(id: id, source: "commit", file: single.file, commit: $0) }
                ?? GitDiff(id: id, source: single.source, file: single.file)
        }
        switch source.indexOfSelectedItem {
        case 1: return GitDiff(id: id, source: "unstaged")
        case 2: return GitDiff(id: id, source: "staged")
        case 3: return GitDiff(id: id, source: "branch")
        case 4: return GitDiff(id: id, source: "commit", commit: commitHash ?? "HEAD")
        case 5:
            // The agent whose turns the picker lists, not whichever has the focus by now.
            let listed = (turnPop.itemArray.first?.representedObject as? SessionTurns.Mark)?.session
            var turn = GitDiff(id: id, source: "turn", session: listed ?? FileActions(app).targetAgent?.id ?? "")
            turn.turn = chosenTurn
            return turn
        default: return GitDiff(id: id, source: "all")
        }
    }

    /// One read at a time: what asks meanwhile (git events, a click) makes one more read after it, not one each. A caller
    /// gets a diff read after it asked.
    private var reading: Task<Void, Never>?
    private var readAgain = false
    /// Counts changes to what's asked (another source or workspace): a read of the old one drops its answer.
    private var asking = 0
    /// What the diff on screen was read from: a git event that leaves it as it was reads nothing.
    private var basis: GitDiff.Basis?

    func load() async {
        if let running = reading {
            readAgain = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                readAgain = false
                await loadOnce()
            } while readAgain
            reading = nil   // with the last check: no await between, so a later caller starts a new one
        }
        reading = task
        await task.value
    }

    /// Reads so far: tests see a burst of events make one more, not one each.
    private(set) var reads = 0

    private func loadOnce() async {
        reads += 1
        guard let wid = worktreeId else {
            builds += 1
            diffs = []
            rows = []
            table.reloadData()
            files.reloadData()
            return
        }
        if single == nil, source.indexOfSelectedItem == 4, askCommit {
            askCommit = false   // before asking: a load that starts while the question is up doesn't ask again
            let log = await app.call(GitLog(id: wid, all: true)) ?? []   // the user picked "a commit": a banner if git can't list them
            let menu = NSMenu()
            for commit in log.prefix(30) {
                let item = menu.addItem(withTitle: "\(commit.hash)  \(commit.subject)", action: nil, keyEquivalent: "")
                item.representedObject = commit.hash
            }
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
            pop.menu = menu
            let alert = NSAlert()
            alert.messageText = String(localized: "Review which commit?")
            alert.accessoryView = pop
            alert.addButton(withTitle: String(localized: "Show"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if await runSheet(alert) == .alertFirstButtonReturn {
                commitHash = pop.selectedItem?.representedObject as? String
            } else {
                source.selectItem(at: 0)
                commitHash = nil
            }
        }
        askCommit = false
        let agent = FileActions(app).targetAgent?.id   // read once: the focus can move during the reads below
        if single == nil, source.indexOfSelectedItem == 5, agent == nil {
            builds += 1
            diffs = []
            rows = []
            words = [:]
            files.reloadData()
            table.reloadData()
            status.stringValue = String(localized: "No agent on this screen")
            return
        }
        if single == nil { await readTurns(source.indexOfSelectedItem == 5 ? agent : nil) }
        let asked = asking, request = diffRequest()
        basis = request.basis(app.latest(GitEvent.self, wid))
        let result = await app.tryCall(request)
        let newDiffs = result.value ?? []
        var ch: [FileChange] = [], cm: [DiffComment] = []
        if single == nil, result.error == nil {   // the files' letters and the comments: the diff above already said what failed
            // The letters as pushed for this workspace (a review tab watches it), else asked.
            if let pushed = app.latest(GitEvent.self, wid)?.changes {
                ch = pushed
            } else {
                ch = await app.quiet(GitStatus(id: wid)) ?? []
            }
            cm = (await app.quiet(CommentList(id: wid)) ?? []).filter { [on = shownCommit] in $0.isOn(on) }   // a past commit's on its diff
        }
        if newDiffs != diffs { opened = [:] }   // lines opened between changes may have moved
        let grammars = newDiffs == diffs ? [:] : DiffColors.grammars(newDiffs)   // the same diff keeps its colours
        async let parsed = Task.detached { DiffColors.spans(newDiffs, grammars: grammars) }.value
        let layout = sideBySide, built = await buildRows(newDiffs, cm, sideBySide: layout)
        let printed = await Task.detached {
            Dictionary(newDiffs.map { ($0.path, ViewedFiles.print($0)) }) { a, _ in a }
        }.value
        let spans = await parsed
        // Rows, cell tags and the hunk buttons index `diffs`: they change together, once every answer is in.
        guard asked == asking, wid == worktreeId else { return }
        builds += 1   // rows a layout change is still building are the old diff's
        if newDiffs != diffs {
            position.stringValue = ""
            syntax = spans
        }   // "Change 3 of 17" counted another diff
        diffs = newDiffs
        prints = printed
        changes = ch
        comments = cm
        readViewed()
        (rows, words) = built
        placeDraft()
        files.reloadData()
        reloadKeepingDraft()
        if !find.needle.isEmpty { search(find.needle, step: false) }
        if layout != sideBySide { rebuildRows() }   // the layout changed while these were built
        if let error = result.error {
            status.stringValue = error
            return
        }   // why there's nothing, not "0 files"
        status.stringValue = statusText()
    }

    /// Counts row builds: one that a newer build or a new diff overtook drops its rows.
    private var builds = 0

    // MARK: table
    func numberOfRows(in t: NSTableView) -> Int { t === files ? diffs.count : rows.count }

    /// The file list's rows light up under the pointer as every inspector list's do; the diff's own rows don't.
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if t === files { return ListRowView() }
        let rowView = DiffLineRowView()   // a line shows a "+" under the pointer, for a comment on it
        rowView.onPlus = shownLine(row) != nil && worktreeId != nil ? { [weak self] in self?.openDraft(at: row) } : nil
        return rowView
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let app = self.app
        if t === files { return fileRow(row) }
        let id = col?.identifier.rawValue ?? ""
        let first = id == "t" || id == "l" || col == nil   // nil: a hunk header, one view across the row
        switch rows[row] {
        case .draft: return draftCard()
        case .comment(let comment): return commentRow(comment)
        case .diff(let diffRow):
            switch diffRow {
            case .file(let path, let added, let removed): return fileBand(path, added: added, removed: removed)
            case .binary(let path):
                return label(
                    first ? String(localized: "Binary file \(path) not shown") : "", font: font,
                    color: .secondaryLabelColor)
            case .tooLarge(let path):
                let said = label(
                    first ? String(localized: "\(path) is too large to show here") : "", font: font,
                    color: .secondaryLabelColor)
                guard first, let uri = alone(path) else { return said }
                said.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let open = ClosureButton(title: String(localized: "Open Changes")) { app.workbench.open(uri) }
                open.bezelStyle = .push
                open.controlSize = .small
                let stack = NSStackView(views: [said, open])
                stack.spacing = 8
                return stack
            case .gap(let file, let from, let count, let context):
                return first ? gapRow(file: file, from: from, lines: count, context: context) : band("")
            case .hunk(let file, let hunk, let header):
                return first ? hunkRow(file: file, hunk: hunk, header: header) : band("")
            case .line(let file, let line):
                switch id {
                case "on": return number(line.oldLine, kind: line.kind)
                case "nn": return number(line.newLine, kind: line.kind)
                default: return codeCell(line, file: file, marker: true)
                }
            case .pair(let file, let left, let right):
                switch id {
                case "on": return left.map { number($0.oldLine, kind: $0.kind) } ?? filler()
                case "nn": return right.map { number($0.newLine, kind: $0.kind) } ?? filler()
                case "l": return left.map { codeCell($0, file: file, marker: false) } ?? filler()
                default: return right.map { codeCell($0, file: file, marker: false) } ?? filler()
                }
            }
        }
    }

    /// A hunk's header spans both sides, its buttons at the row's end, rather than ending halfway in an empty strip.
    /// A hunk's header and a file's band run across the row.
    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool {
        guard t === table, rows.indices.contains(row) else { return false }
        switch rows[row] {
        case .diff(.hunk), .diff(.file), .draft, .comment: return true
        default: return false
        }
    }
    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat { t === table ? height(of: row) : t.rowHeight }

}

extension DiffViewController {
    /// The table's rows and changed words, built off the main thread: a big diff is a lot of rows.
    private func buildRows(_ d: [FileDiff], _ cm: [DiffComment], sideBySide: Bool) async -> (
        [ReviewRow], [String: NSRange]
    ) {
        let one = single != nil, open = opened
        return await Task.detached {
            (
                DiffRows.reviewRows(d, comments: cm, sideBySide: sideBySide, hideFileRows: one, opened: open),
                DiffRows.changedWords(d)
            )
        }.value
    }

    func rebuildRows() {
        builds += 1
        let generation = builds, currentDiffs = diffs, cm = comments, layout = sideBySide
        Task {
            let built = await buildRows(currentDiffs, cm, sideBySide: layout)
            guard generation == builds else { return }
            if fadesNextLoad { table.crossfade(Motion.base) }
            fadesNextLoad = false
            (rows, words) = built
            placeDraft()
            reloadKeepingDraft()
            if !find.needle.isEmpty { search(find.needle, step: false) }
        }
    }

    /// Source Control beside the tab lists the same files: the tab's own list steps aside meanwhile, and comes back
    /// where it was when the inspector closes or shows another panel. One file's tab has none.
    func placeFileList() {
        let hide = single != nil || app.workbench.panelBeside == "git.changes"
        guard let list = fileList, let split, list.isHidden != hide else { return }
        list.isHidden = hide
        split.adjustSubviews()
        if !hide { positioned = false }   // at its width again on the next layout
    }

    /// Whether the hunks shown are the staged diff's (Unstage) or the unstaged one's (Stage); nil where they're neither
    /// and git can't take them as they are. The uncommitted diff (against HEAD) is the unstaged one's for a file with
    /// nothing staged, and the staged one's for a file with nothing left unstaged.
    func hunksStaged(_ f: Int) -> Bool? {
        if hidesSpace { return nil }
        if let single {
            return single.commit == nil && (single.source == "unstaged" || single.source == "staged")
                ? single.source == "staged" : nil
        }
        switch source.indexOfSelectedItem {
        case 1: return false
        case 2: return true
        case 0:
            guard diffs.indices.contains(f) else { return nil }
            guard let change = changes.first(where: { $0.path == diffs[f].path }), change.staged else { return false }
            return change.unstaged ? nil : true
        default: return nil
        }
    }

    /// One file of the review in a tab of its own, which has room for a whole file's changes; nil for the agent's last turn.
    private func alone(_ path: String) -> String? {
        guard single == nil, let wid = worktreeId else { return nil }
        switch source.indexOfSelectedItem {
        case 1: return DiffTab.uri(wid, file: path, source: "unstaged")
        case 2: return DiffTab.uri(wid, file: path, source: "staged")
        case 3: return DiffTab.uri(wid, file: path, source: "branch")
        case 4: return DiffTab.uri(wid, file: path, commit: commitHash ?? "HEAD")
        case 5: return nil
        default: return DiffTab.uri(wid, file: path, source: "all")
        }
    }
}
