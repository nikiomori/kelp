import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// What a file's tab shows of how the file differs from HEAD: bars beside the line numbers, followed from what git and the
/// disk say (a host's project too, git runs there), and a card with the change when one is clicked.
@MainActor
final class ChangeBars {
    private let app: AppModel, editor: CodeEditor, worktree: Worktree, file: String
    private let isEdited: () -> Bool
    private let git: Watched
    private let refreshing = Debounce()
    private var reading: Task<Void, Never>?
    private var hunks: [Hunk] = []
    private var card: NSPopover?
    private struct Seen: Equatable { let changes: [FileChange], branches: BranchInfo? }

    /// Nil for a file outside the workspaces.
    init?(app: AppModel, path: String, editor: CodeEditor, isEdited: @escaping () -> Bool) {
        guard let w = app.worktrees.filter({ path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) else { return nil }
        self.app = app
        self.editor = editor
        self.isEdited = isEdited
        worktree = w
        file = String(path.dropFirst(w.path.count + 1))
        git = Watched(.git, in: app)
        git.key = w.id
        editor.onChangeMark = { [weak self] m, at, view in self?.show(m, at: at, in: view) }
        let id = w.id, mine = file
        // This file's line in the status and the branch: a change to other files says nothing about its bars (the disk's
        // changes to it come through `refresh` from its tab).
        track(owner: self) { [app] in Seen(changes: app.git[id]?.changes?.filter { $0.path == mine } ?? [], branches: app.git[id]?.branches) }
            changed: { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Not while the buffer has edits: the file on disk says nothing about them, and typing moves the bars along meanwhile.
    func refresh() {
        refreshing.after(0.2) { [weak self] in self?.read() }
    }

    private func read() {
        guard !isEdited() else { return }
        reading?.cancel()
        let wid = worktree.id, file = file
        reading = Task { [weak self] in
            // Quiet: a folder outside git has no bars, and that's no failure.
            guard let diff = await self?.app.quiet(GitDiff(id: wid, file: file)), !Task.isCancelled, let self else { return }
            hunks = diff.first?.hunks ?? []
            editor.changeMarks = LineChange.of(hunks).map(Self.mark)
        }
    }

    private static func mark(_ c: LineChange) -> CodeEditor.ChangeMark {
        let kind: CodeEditor.ChangeMark.Kind = switch c.kind {
        case .added: .added
        case .changed: .changed
        case .removed: .removed
        }
        return CodeEditor.ChangeMark(kind: kind, line: c.line, count: c.count, hunk: c.hunk)
    }

    // MARK: the card

    private func show(_ m: CodeEditor.ChangeMark, at: NSRect, in view: NSView) {
        guard hunks.indices.contains(m.hunk) else { return }
        let shown = hunks[m.hunk], wid = worktree.id, file = file
        Task { [weak self] in
            // Stage and Revert work on what isn't staged yet, as `git.hunk` finds it: the same lines of the unstaged diff.
            let unstaged = await self?.app.quiet(GitDiff(id: wid, source: "unstaged", file: file))?.first?.hunks ?? []
            guard let self else { return }
            let hunk = Self.counterpart(of: shown, in: unstaged)
            let p = NSPopover()
            p.behavior = .transient
            p.contentViewController = ChangeCard(shown: shown, actions: buttons(hunk))
            card = p
            p.show(relativeTo: at, of: view, preferredEdge: .maxX)
        }
    }

    /// The hunk over the same new lines.
    static func counterpart(of h: Hunk, in others: [Hunk]) -> Hunk? {
        let lines = Set(h.lines.compactMap(\.newLine))
        return others.first { o in o.lines.contains { $0.kind != .context && $0.newLine.map(lines.contains) == true } }
            ?? others.first { $0.newStart == h.newStart }
    }

    private func buttons(_ hunk: Hunk?) -> [NSView] {
        var out: [NSView] = []
        func add(_ title: String, _ go: @escaping () -> Void) {
            let b = PointerButton()
            b.title = title
            b.padding = Metrics.gap
            b.restFill = .fillRest
            b.onClick = { [weak self] in self?.card?.close(); go() }
            out.append(b)
        }
        // With edits in the buffer the file isn't what was diffed.
        if let hunk, !isEdited() {
            add(String(localized: "Revert…")) { [weak self] in self?.revert(hunk) }
            add(String(localized: "Stage")) { [weak self] in self?.stage(hunk) }
        }
        let uri = TabURI.diff(worktree.id, file: file)
        add(String(localized: "Open in Diff")) { [app] in app.workbench.open(uri, split: .right) }
        return out
    }

    private func stage(_ h: Hunk) {
        let m = GitHunk(id: worktree.id, file: file, header: h.header, fingerprint: h.fingerprint), id = worktree.id
        Task { [app] in if await app.call(m) != nil { app.watchAgain(.git, id) } }
    }

    /// The change goes at once: the banner's Undo brings it back.
    private func revert(_ h: Hunk) {
        let name = (file as NSString).lastPathComponent
        let m = GitDiscardHunk(id: worktree.id, file: file, hunk: 0, header: h.header, fingerprint: h.fingerprint), id = worktree.id
        Task { [app] in
            guard await app.call(m) != nil else { return }
            app.watchAgain(.git, id)
            Banner.show(String(localized: "Discarded a change in \(name)"), action: (String(localized: "Undo"), {
                Task { await app.call(GitUndoDiscard(id: id)); app.watchAgain(.git, id) }   // the daemon keeps it a minute
            }))
        }
    }
}

/// The change in a popover: its lines in the diff's colours, and what can be done with it.
final class ChangeCard: NSViewController {
    private static let mostLines = 24, width: CGFloat = 460
    private let shown: Hunk, actions: [NSView]
    init(shown: Hunk, actions: [NSView]) {
        self.shown = shown
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let text = NSTextField(labelWithAttributedString: lines())
        text.maximumNumberOfLines = 0
        text.lineBreakMode = .byTruncatingTail
        text.preferredMaxLayoutWidth = Self.width
        let bar = NSStackView(views: actions)
        bar.spacing = Metrics.gap
        let stack = NSStackView(views: [text, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        view = stack
        preferredContentSize = stack.fittingSize   // what the popover opens at
    }

    private func lines() -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular), out = NSMutableAttributedString()
        let changed = shown.lines.filter { $0.kind != .context }
        for l in changed.prefix(Self.mostLines) {
            let (sign, color): (String, NSColor) = l.kind == .add ? ("+ ", .textGreen) : ("- ", .textRed)
            out.append(NSAttributedString(string: sign + l.text + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        if changed.count > Self.mostLines {
            let more = String(localized: "and \(changed.count - Self.mostLines) more")
            out.append(NSAttributedString(string: more, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        } else if out.length > 0 { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }
}
