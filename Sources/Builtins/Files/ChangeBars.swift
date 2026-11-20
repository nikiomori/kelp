import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// Shows in a file's tab how the file differs from HEAD: bars beside the line numbers, and a card with the change
/// when a bar is clicked. The bars follow what git and the disk report. A project on a host works too, because git
/// runs there.
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

    /// `file` is the file's path inside `worktree`, as `project(of:in:)` returns it.
    init(app: AppModel, worktree: Worktree, file: String, editor: CodeEditor, isEdited: @escaping () -> Bool) {
        self.app = app
        self.editor = editor
        self.isEdited = isEdited
        self.worktree = worktree
        self.file = file
        git = Watched(.git, in: app)
        git.key = app.gitKey(worktree.id)
        editor.onChangeMark = { [weak self] m, at, view in self?.show(m, at: at, in: view) }
        let id = worktree.id, mine = file
        // Watches only this file's entries in the git status, and the branch, because a change to other files doesn't
        // move this file's bars. Changes to the file on disk come through `refresh`, which the file's tab calls.
        track(owner: self) { [app] in
            let git = app.latest(GitEvent.self, app.gitKey(id))
            return Seen(changes: git?.changes?.filter { $0.path == mine } ?? [], branches: git?.branches)
        } changed: { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    /// Returns the innermost workspace holding `path`, and the path inside it. Real paths count too, so a file opened
    /// through a symlink (/tmp is /private/tmp) still belongs to its project. Only the file's folder is resolved, not
    /// the file itself, so a link to a file elsewhere stays in the project where it was opened.
    static func project(of path: String, in worktrees: [Worktree]) -> (worktree: Worktree, file: String)? {
        let url = URL(fileURLWithPath: path), folder = url.deletingLastPathComponent().path
        let real = (Paths.real(folder) ?? folder) + "/" + url.lastPathComponent
        let found = worktrees.compactMap { worktree -> (Worktree, String)? in
            for (candidate, base) in [(path, worktree.path), (real, Paths.real(worktree.path) ?? worktree.path)] {
                if let inside = Paths.relative(candidate, to: base) { return (worktree, inside) }
            }
            return nil
        }
        return found.max { $0.0.path.count < $1.0.path.count }.map { (worktree: $0.0, file: $0.1) }
    }

    /// Reads the bars again after a short pause. `read` skips this while the buffer has edits, because the file on disk
    /// says nothing about them, and typing moves the bars along meanwhile.
    func refresh() {
        refreshing.after(0.2) { [weak self] in self?.read() }
    }

    private func read() {
        guard !isEdited() else { return }
        reading?.cancel()
        let wid = worktree.id, file = file
        reading = Task { [weak self] in
            // `quiet`, because a folder outside git simply has no bars, and that isn't a failure.
            guard let diff = await self?.app.quiet(GitDiff(id: wid, file: file)), !Task.isCancelled, let self else {
                return
            }
            hunks = diff.first?.hunks ?? []
            editor.changeMarks = LineChange.of(hunks)
        }
    }

    // MARK: the card

    private func show(_ mark: CodeEditor.ChangeMark, at: NSRect, in view: NSView) {
        guard hunks.indices.contains(mark.hunk) else { return }
        let shown = hunks[mark.hunk]
        Task { [weak self] in
            let hunk = await self?.unstaged(shown)
            guard let self else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = ChangeCard(shown: shown, actions: buttons(hunk))
            card = popover
            popover.show(relativeTo: at, of: view, preferredEdge: .maxX)
        }
    }

    /// Stage and Revert act on changes not staged yet, as `git.hunk` finds them, so they use the hunk over the same
    /// lines as `shown` in the unstaged diff.
    private func unstaged(_ shown: Hunk) async -> Hunk? {
        let unstaged = await app.quiet(GitDiff(id: worktree.id, source: .unstaged, file: file))?.first?.hunks ?? []
        return Self.counterpart(of: shown, in: unstaged)
    }

    /// Whether the caret's line has a change that Revert and Stage can act on (not while the buffer has edits, because
    /// the file isn't what was diffed then).
    var changeAtCursor: Bool {
        !isEdited() && editor.changeAtCursor.map { hunks.indices.contains($0.hunk) } == true
    }

    /// Reverts the change on the caret's line (`revert`), or stages it, as the card's buttons do.
    func actOnChangeAtCursor(revert: Bool) {
        guard changeAtCursor, let mark = editor.changeAtCursor else { return NSSound.beep() }
        let shown = hunks[mark.hunk]
        Task { [weak self] in
            guard let hunk = await self?.unstaged(shown), let self else { return }
            if revert { self.revert(hunk) } else { stage(hunk) }
        }
    }

    /// Returns the hunk in `others` that changes any of the same new lines as `hunk`, or else the one that starts on
    /// the same line as `hunk`.
    static func counterpart(of hunk: Hunk, in others: [Hunk]) -> Hunk? {
        let lines = Set(hunk.lines.compactMap(\.newLine))
        return others.first { o in o.lines.contains { $0.kind != .context && $0.newLine.map(lines.contains) == true } }
            ?? others.first { $0.newStart == hunk.newStart }
    }

    private func buttons(_ hunk: Hunk?) -> [NSView] {
        var out: [NSView] = []
        func add(_ title: String, _ go: @escaping () -> Void) {
            out.append(
                TextButton(title) { [weak self] in
                    self?.card?.close()
                    go()
                })
        }
        // While the buffer has edits, the file isn't what was diffed, so Revert and Stage are left out.
        if let hunk, !isEdited() {
            add(String(localized: "Revert")) { [weak self] in self?.revert(hunk) }   // at once, Undo in its banner
            add(String(localized: "Stage")) { [weak self] in self?.stage(hunk) }
        }
        let uri = TabURI.diff(worktree.id, file: file)
        add(String(localized: "Open in Diff")) { [app] in app.workbench.open(uri, split: .right) }
        return out
    }

    private func stage(_ hunk: Hunk) {
        let request = GitHunk(id: worktree.id, file: file, header: hunk.header, fingerprint: hunk.fingerprint),
            id = worktree.id
        Task { [app] in if await app.call(request) != nil { app.watchAgain(.git, app.gitKey(id)) } }
    }

    /// Discards the change at once, without asking, because the banner's Undo brings it back.
    private func revert(_ hunk: Hunk) {
        let name = (file as NSString).lastPathComponent
        Task { [app, file, id = worktree.id] in
            await discardWithUndo(
                app,
                {
                    GitDiscardHunk(
                        id: id, file: file, hunk: 0, header: hunk.header, fingerprint: hunk.fingerprint, undo: $0)
                },
                saying: String(localized: "Discarded a change in \(name)"), worktree: id)
        }
    }
}

/// The popover that shows a change: its lines in the diff's colours, and buttons for what can be done with it.
final class ChangeCard: NSViewController {
    private static let mostLines = 24, width = Metrics.codeCardWidth
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
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        view = stack
        preferredContentSize = stack.fittingSize   // the size the popover opens at
    }

    private func lines() -> NSAttributedString {
        let font = CodeEditor.font, out = NSMutableAttributedString()   // the editor's font, as the diff uses
        let changed = shown.lines.filter { $0.kind != .context }
        for line in changed.prefix(Self.mostLines) {
            let (sign, color): (String, NSColor) = line.kind == .add ? ("+ ", .textGreen) : ("- ", .textRed)
            out.append(
                NSAttributedString(string: sign + line.text + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        if changed.count > Self.mostLines {
            let more = String(localized: "and \(changed.count - Self.mostLines) more")
            out.append(
                NSAttributedString(
                    string: more, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        } else if out.length > 0 {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }
}
