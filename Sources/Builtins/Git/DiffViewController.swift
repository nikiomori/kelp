import AppKit
import Core
import DesignKit
import EditorKit
import WorkbenchKit
import KelpKit

final class DiffTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

/// Diffs the way VS Code shows them: side by side (or inline), whole-line red / green, the changed words darker,
/// hatching where one side has no line. One file (from Source Control) or every change with review comments for the agent.
@MainActor
final class DiffViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    let source = NSPopUpButton()
    private let layoutToggle = NSSegmentedControl(images: [.symbol("rectangle.split.2x1", String(localized: "Side by Side")),
                                                           .symbol("rectangle", String(localized: "Inline"))],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    let files = NSTableView()
    let table = DiffTable()
    let status = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    var diffs: [FileDiff] = []
    var rows: [ReviewRow] = []
    var comments: [DiffComment] = []
    var changes: [FileChange] = []
    /// Changed character range of a line that has a counterpart on the other side, by "file:kind:line".
    var words: [String: NSRange] = [:]
    var worktreeId: String?
    private var commitHash: String?
    /// One-file mode: (path, "unstaged" | "staged", commit).
    var single: (file: String, source: String, commit: String?)?
    /// The editor's font and size, as the code it shows is the editor's; a row is a line of it and 4 pt.
    var font: NSFont { CodeEditor.font }
    static var lineHeight: CGFloat { let f = CodeEditor.font; return (f.ascender - f.descender + f.leading).rounded(.up) + 4 }
    /// Side by side when chosen and there's room for two columns; a narrow pane shows it inline (like VS Code).
    private var sideBySide: Bool { layoutToggle.selectedSegment == 0 && !narrow }
    private var narrow = false

    static let addTint = NSColor.systemGreen.withAlphaComponent(0.14), delTint = NSColor.systemRed.withAlphaComponent(0.14)
    static let addWord = NSColor.systemGreen.withAlphaComponent(0.32), delWord = NSColor.systemRed.withAlphaComponent(0.32)
    static let hatch = NSColor(patternImage: NSImage(size: NSSize(width: 7, height: 7), flipped: false) { _ in
        NSColor.secondaryLabelColor.withAlphaComponent(0.14).setStroke()
        let p = NSBezierPath()
        p.move(to: .zero)
        p.line(to: NSPoint(x: 7, y: 7))
        p.lineWidth = 1
        p.stroke()
        return true
    })

    override func loadView() {
        layoutToggle.selectedSegment = UserDefaults.standard.bool(forKey: "diff.inline") ? 1 : 0
        layoutToggle.target = self; layoutToggle.action = #selector(layoutChanged)
        layoutToggle.setToolTip(String(localized: "Side by Side"), forSegment: 0); layoutToggle.setToolTip(String(localized: "Inline"), forSegment: 1)
        source.addItems(withTitles: [String(localized: "Uncommitted"), String(localized: "Unstaged"), String(localized: "Staged"),
                                     String(localized: "Branch vs base"), String(localized: "Commit…"), String(localized: "Agent's Last Turn")])
        source.lastItem?.toolTip = String(localized: "What changed since the agent's last prompt, even with other agents in the same folder")
        source.target = self
        source.action = #selector(sourceChanged)
        source.controlSize = .small
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead; pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fc = NSTableColumn(identifier: .init("file")); fc.title = String(localized: "Files")
        files.addTableColumn(fc)
        files.dataSource = self
        files.delegate = self
        files.rowHeight = 26
        files.style = .sourceList
        files.headerView = nil
        fc.resizingMask = .autoresizingMask; files.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle   // rows as wide as the pane
        let fm = NSMenu(); fm.addItem(withTitle: String(localized: "Stage"), action: #selector(stageFile), keyEquivalent: "").target = self
        fm.addItem(withTitle: String(localized: "Unstage"), action: #selector(unstageFile), keyEquivalent: "").target = self
        files.menu = fm
        let fs = NSScrollView()
        fs.documentView = files
        fs.hasVerticalScroller = true
        fs.drawsBackground = false

        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.lineHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.style = .plain
        table.allowsMultipleSelection = true
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = CodeEditor.page.background; table.floatsGroupRows = false
        table.onKey = { [weak self] e in self?.key(e) ?? false }
        let cm = NSMenu()
        for (t, st) in [(String(localized: "Mark Resolved"), "resolved"), (String(localized: "Reopen"), "open")] {
            let i = cm.addItem(withTitle: t, action: #selector(setCommentState(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = st
        }
        table.menu = cm
        let ts = NSScrollView()
        ts.documentView = table
        ts.hasVerticalScroller = true
        ts.autohidesScrollers = true
        setColumns()

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(fs); split.addArrangedSubview(ts)
        fs.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        ts.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        self.split = split; fileList = fs
        buildBar()
        view = stacked(bar, split)
        track(owner: self) { [app] in app.themes.editorRevision } changed: { [weak self] _ in self?.themeChanged() }
    }

    /// The editor's theme or font changed: the code here follows.
    private func themeChanged() {
        table.backgroundColor = CodeEditor.page.background
        table.rowHeight = Self.lineHeight
        rebuildRows()
    }

    private let bar = Bar.content([])
    private var split: NSSplitView?
    private var fileList: NSView?
    private var positioned = false
    override func viewDidLayout() {
        super.viewDidLayout()
        if single == nil, !positioned, let s = split, s.bounds.width > 400 { positioned = true; s.setPosition(220, ofDividerAt: 0) }
        let n = table.bounds.width > 0 && table.bounds.width < 640
        if n != narrow {
            narrow = n
            layoutToggle.setEnabled(!n, forSegment: 0)
            layoutToggle.setToolTip(n ? String(localized: "Side by Side (needs a wider pane)") : String(localized: "Side by Side"), forSegment: 0)
            setColumns(); rebuildRows()
        }
    }

    private func buildBar() {
        if single != nil {
            let steps = NSSegmentedControl.steps(previous: String(localized: "Previous Change (⌥↑)"), next: String(localized: "Next Change (⌥↓)"),
                                                 target: self, action: #selector(stepped(_:)))
            bar.set([pathLabel, status], [steps, layoutToggle])
        } else {
            func btn(_ t: String, _ a: Selector) -> NSButton {
                let b = NSButton(title: t, target: self, action: a)
                b.bezelStyle = .push
                b.controlSize = .small
                return b
            }
            bar.set([source, layoutToggle, btn(String(localized: "Comment"), #selector(addComment)),
                     btn(String(localized: "Send to Agent"), #selector(sendComments))], [status])
        }
    }

    @objc private func stepped(_ s: NSSegmentedControl) { if s.selectedSegment == 0 { prevChange() } else { nextChange() } }

    private func setColumns() {
        table.tableColumns.forEach(table.removeTableColumn)
        for id in sideBySide ? ["on", "l", "nn", "r"] : ["on", "nn", "t"] {
            let c = NSTableColumn(identifier: .init(id))
            if id == "on" || id == "nn" {
                c.width = 44
                c.resizingMask = []
            } else {
                c.width = 400
                c.minWidth = 120
                c.resizingMask = .autoresizingMask
            }
            table.addTableColumn(c)
        }
        table.sizeToFit()
    }

    func show(worktree id: String?) {
        worktreeId = id; asking += 1
        Task { await load() }
    }

    /// One file, VS Code's diff editor: no file list, just this file's changes.
    func showFile(_ path: String, source: String, commit: String?) {
        single = (path, source, commit)
        fileList?.isHidden = true
        let dir = (path as NSString).deletingLastPathComponent
        let s = NSMutableAttributedString(string: (path as NSString).lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        if !dir.isEmpty {
            s.append(NSAttributedString(string: "  " + dir,
                                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        pathLabel.attributedStringValue = s
        buildBar()
    }

    @objc func reload() { Task { await load() } }
    /// Git changed while the tab was in the background: it reads the diff again when shown, not on every save meanwhile.
    var stale = false
    override func viewDidAppear() {
        super.viewDidAppear()
        if stale { stale = false; reload() }
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
        setColumns(); rebuildRows()
    }

    private func diffRequest() -> GitDiff {
        let id = worktreeId ?? ""
        if let s = single {
            return s.commit.map { GitDiff(id: id, source: "commit", file: s.file, commit: $0) } ?? GitDiff(id: id, source: s.source, file: s.file)
        }
        switch source.indexOfSelectedItem {
        case 1: return GitDiff(id: id, source: "unstaged")
        case 2: return GitDiff(id: id, source: "staged")
        case 3: return GitDiff(id: id, source: "branch")
        case 4: return GitDiff(id: id, source: "commit", commit: commitHash ?? "HEAD")
        case 5: return GitDiff(id: id, source: "turn", session: FileActions(app).targetAgent?.id ?? "")
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
        let t = Task {
            repeat { readAgain = false; await loadOnce() } while readAgain
            reading = nil   // with the last check: no await between, so a later caller starts a new one
        }
        reading = t
        await t.value
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
            for c in log.prefix(30) {
                let m = menu.addItem(withTitle: "\(c.hash)  \(c.subject)", action: nil, keyEquivalent: "")
                m.representedObject = c.hash
            }
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26)); pop.menu = menu
            let a = NSAlert()
            a.messageText = String(localized: "Review which commit?")
            a.accessoryView = pop
            a.addButton(withTitle: String(localized: "Show")); a.addButton(withTitle: String(localized: "Cancel"))
            if await runSheet(a) == .alertFirstButtonReturn {
                commitHash = pop.selectedItem?.representedObject as? String
            } else {
                source.selectItem(at: 0)
                commitHash = nil
            }
        }
        askCommit = false
        if single == nil, source.indexOfSelectedItem == 5, FileActions(app).targetAgent == nil {
            builds += 1
            diffs = []
            rows = []
            words = [:]
            files.reloadData()
            table.reloadData()
            status.stringValue = String(localized: "No agent in this workspace"); return
        }
        let asked = asking, request = diffRequest()
        basis = request.basis(app.git[wid])
        let r = await app.tryCall(request)
        let d = r.value ?? []
        var ch: [FileChange] = [], cm: [DiffComment] = []
        if single == nil, r.error == nil {   // the files' letters and the comments: the diff above already said what failed
            // The letters as pushed for this workspace (a review tab watches it), else asked.
            if let pushed = app.git[wid]?.changes { ch = pushed } else { ch = await app.quiet(GitStatus(id: wid)) ?? [] }
            cm = await app.quiet(CommentList(id: wid)) ?? []
        }
        let layout = sideBySide, built = await buildRows(d, cm, sideBySide: layout)
        // Rows, cell tags and the hunk buttons index `diffs`: they change together, once every answer is in.
        guard asked == asking, wid == worktreeId else { return }
        builds += 1   // rows a layout change is still building are the old diff's
        diffs = d
        changes = ch
        comments = cm
        (rows, words) = built
        files.reloadData(); table.reloadData()
        if layout != sideBySide { rebuildRows() }   // the layout changed while these were built
        if let e = r.error { status.stringValue = e; return }   // why there's nothing, not "0 files"
        let add = diffs.reduce(0) { $0 + $1.additions }, del = diffs.reduce(0) { $0 + $1.deletions }
        let open = comments.filter { $0.state == .open }.count
        status.stringValue = single != nil ? (diffs.isEmpty ? String(localized: "No changes") : RowBadges.changes(added: add, removed: del).string)
            : String(localized: "\(diffs.count) files") + "  \(RowBadges.changes(added: add, removed: del).string)"
            + (open > 0 ? "  ·  " + String(localized: "\(open) open comments") : "")
    }

    /// The table's rows and changed words, built off the main thread: a big diff is a lot of rows.
    private func buildRows(_ d: [FileDiff], _ cm: [DiffComment], sideBySide: Bool) async -> ([ReviewRow], [String: NSRange]) {
        let one = single != nil
        return await Task.detached { (DiffRows.reviewRows(d, comments: cm, sideBySide: sideBySide, hideFileRows: one), DiffRows.changedWords(d)) }.value
    }

    /// Counts row builds: one that a newer build or a new diff overtook drops its rows.
    private var builds = 0
    private func rebuildRows() {
        builds += 1
        let n = builds, d = diffs, cm = comments, layout = sideBySide
        Task {
            let built = await buildRows(d, cm, sideBySide: layout)
            guard n == builds else { return }
            (rows, words) = built; table.reloadData()
        }
    }

    // MARK: table
    func numberOfRows(in t: NSTableView) -> Int { t === files ? diffs.count : rows.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let app = self.app
        if t === files { return fileRow(row) }
        let id = col?.identifier.rawValue ?? ""
        let first = id == "t" || id == "l" || col == nil   // nil: a hunk header, one view across the row
        switch rows[row] {
        case .comment(let c):
            guard first else { return label("", font: font) }
            let v = label("💬 \(c.text)  [\(c.state.rawValue)]", font: .systemFont(ofSize: 11, weight: .medium))
            v.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.2); v.drawsBackground = true
            return v
        case .diff(let r):
            switch r {
            case .file(let p, let a, let d):
                let v = label(first ? "\(p)   " + RowBadges.changes(added: a, removed: d).string : "", font: .boldSystemFont(ofSize: 12))
                v.backgroundColor = .controlBackgroundColor
                v.drawsBackground = true
                return v
            case .binary(let p): return label(first ? String(localized: "Binary file \(p) not shown") : "", font: font, color: .secondaryLabelColor)
            case .tooLarge(let p):
                let said = label(first ? String(localized: "\(p) is too large to show here") : "", font: font, color: .secondaryLabelColor)
                guard first, let uri = alone(p) else { return said }
                said.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let open = ClosureButton(title: String(localized: "Open Changes")) { app.workbench.open(uri) }
                open.bezelStyle = .push; open.controlSize = .small
                let stack = NSStackView(views: [said, open]); stack.spacing = 8
                return stack
            case .gap(let n): return band(first ? String(localized: "⋯  \(n) unchanged lines") : "")
            case .hunk(let f, let h, let header): return first ? hunkRow(file: f, hunk: h, header: header) : band("")
            case .line(let f, let l):
                switch id {
                case "on": return number(l.oldLine, kind: l.kind)
                case "nn": return number(l.newLine, kind: l.kind)
                default: return codeCell(l, file: f, marker: true)
                }
            case .pair(let f, let l, let r):
                switch id {
                case "on": return l.map { number($0.oldLine, kind: $0.kind) } ?? filler()
                case "nn": return r.map { number($0.newLine, kind: $0.kind) } ?? filler()
                case "l": return l.map { codeCell($0, file: f, marker: false) } ?? filler()
                default: return r.map { codeCell($0, file: f, marker: false) } ?? filler()
                }
            }
        }
    }

    /// A hunk's header spans both sides, its buttons at the row's end, rather than ending halfway in an empty strip.
    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool {
        guard t === table, rows.indices.contains(row), case .diff(.hunk) = rows[row] else { return false }
        return true
    }

    /// Hunk buttons only where the hunks shown are the ones git stages: the unstaged or the staged diff, or the uncommitted
    /// one (against HEAD) for a file with nothing staged, whose hunks are the unstaged diff's.
    func canStageHunks(_ f: Int) -> Bool {
        if let s = single { return s.commit == nil && (s.source == "unstaged" || s.source == "staged") }
        switch source.indexOfSelectedItem {
        case 1, 2: return true
        case 0: return diffs.indices.contains(f) && changes.first { $0.path == diffs[f].path }?.staged != true
        default: return false
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

/// A file-list row: its folder only when the whole of it fits (`full`), else the name and counts alone (`short`).
final class FitLabel: NSTextField {
    var full = NSAttributedString(), short = NSAttributedString()
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let s = full.size().width + 6 <= size.width ? full : short
        if !attributedStringValue.isEqual(to: s) { attributedStringValue = s }
    }
}
