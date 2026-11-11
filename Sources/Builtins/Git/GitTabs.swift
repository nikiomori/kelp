import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// "diff:<workspace>" (every change), "diff:<workspace>?commit=<hash>" (a commit's) or
/// "diff:<workspace>?file=<path>[&source=unstaged|staged][&commit=<hash>]" (one file, like VS Code's diff editor:
/// "name (Working Tree)", "name (Index)", "name (abc1234)").
@MainActor
final class DiffTab: TabContent {
    let worktreeId: String, app: AppModel
    private let controller: DiffViewController
    private let file: String?, source: DiffSource?, commit: String?
    private(set) var uri: String
    var view: NSView { controller.view }
    var title: String {
        guard let file else {
            return commit.map { String($0.prefix(7)) }
                ?? (source == .turn ? String(localized: "Last Turn") : String(localized: "Changes"))
        }
        let what =
            commit.map { String($0.prefix(7)) }
            ?? (source == .staged
                ? String(localized: "Index")
                : source == .branch ? DiffSource.branch.title : String(localized: "Working Tree"))
        return "\((file as NSString).lastPathComponent) (\(what))"
    }
    var icon: NSImage? { .symbol("plus.forwardslash.minus") }
    var toolTip: String? { file }

    init(uri: String, app: AppModel) {
        self.uri = uri
        self.app = app
        controller = DiffViewController(app: app)
        gitWatch = Watched(.git, in: app)
        let components = URLComponents(string: uri)
        worktreeId = components?.path ?? ""
        func item(_ n: String) -> String? { components?.queryItems?.first { $0.name == n }?.value }
        file = item("file")
        source = item("source").flatMap(DiffSource.init(wire:))
        commit = item("commit")
        _ = controller.view
        if let file {
            controller.showFile(file, source: source ?? .unstaged, commit: commit)
        } else if let commit {
            controller.showCommit(commit)
        } else if source == .turn {
            controller.showLastTurn()
        }
        controller.show(worktree: worktreeId)
        // Its workspace's git, pushed when its files change (a commit's diff doesn't change): read the diff again if it
        // changed what the diff is read from.
        guard commit == nil else { return }
        gitWatch.key = worktreeId
        var shown = false   // the first value is what was just loaded
        track(owner: self) { [weak self, app] in
            app.latest(GitEvent.self, self?.worktreeId ?? "")
        } changed: { [weak self] e in
            guard let self, shown else {
                shown = true
                return
            }
            controller.gitChanged(e)
        }
    }
    private let gitWatch: Watched

    func focus() { controller.view.window?.makeFirstResponder(controller.view) }

    static func uri(
        _ worktree: String, file: String? = nil, source: DiffSource? = nil, commit: String? = nil
    ) -> String {
        TabURI.diff(worktree, file: file, source: source?.wire, commit: commit)
    }
}

extension GitDiff {
    /// What of a workspace's git this diff is read from: an event that leaves it as it was (a fetch moving ahead/behind,
    /// a branch made elsewhere; for a branch's or a commit's diff, edits too) needs no new read. Edits and staging show
    /// in the status and the line counts, commits in HEAD.
    struct Basis: Equatable {
        var changes: [FileChange]?, stats: LineStats?, head: String?, branches: BranchInfo?, error: String?
    }

    func basis(_ event: GitEvent?) -> Basis? {
        guard let event else { return nil }
        switch source ?? "all" {
        // HEAD against its base's merge base
        case "branch": return Basis(branches: event.branches, error: event.error)
        case "commit": return Basis(head: commit == "HEAD" ? event.branches?.head : nil, error: event.error)
        case "unstaged", "turn": return Basis(changes: event.changes, stats: event.stats, error: event.error)   // the files against the index, or a snapshot
        default:
            return Basis(changes: event.changes, stats: event.stats, head: event.branches?.head, error: event.error)   // against HEAD
        }
    }
}

/// "commit:<workspace>[?push=1][&amend=1][&message=…]": the commit message as a page, like VS Code's COMMIT_EDITMSG.
/// Commit with an empty message box opens it. Lines starting with "#" are left out; ⌘↩ or Commit commits, closing cancels.
@MainActor
final class CommitMessageTab: TabContent {
    let uri: String, app: AppModel
    private let worktreeId: String, push: Bool, amend: Bool
    private let text = CommitTextView()
    private let root = NSView()
    private let commitButton = NSButton()
    var view: NSView { root }
    var title: String { Self.title(amend: amend) }
    static func title(amend: Bool) -> String {
        amend ? String(localized: "Amend Commit") : String(localized: "Commit Message")
    }
    var icon: NSImage? { .symbol("square.and.pencil") }

    init(uri: String, app: AppModel) {
        self.uri = uri
        self.app = app
        let components = URLComponents(string: uri), query = components?.queryItems ?? []
        worktreeId = components?.path ?? ""
        push = query.contains { $0.name == "push" }
        amend = query.contains { $0.name == "amend" }
        build()
        let message = query.first { $0.name == "message" }?.value ?? ""
        Task { await fill(message) }
    }

    static func uri(_ worktree: String, push: Bool = false, amend: Bool = false, message: String? = nil) -> String {
        var components = URLComponents()
        components.queryItems = [
            push ? URLQueryItem(name: "push", value: "1") : nil, amend ? URLQueryItem(name: "amend", value: "1") : nil,
            message.map { URLQueryItem(name: "message", value: $0) }
        ].compactMap { $0 }
        return "commit:\(worktree)"
            + (components.queryItems?.isEmpty == false ? "?" + (components.percentEncodedQuery ?? "") : "")
    }

    private func build() {
        text.isRichText = false
        text.allowsUndo = true
        text.font = CodeEditor.font   // a commit message is written in the editor's font, at its size
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true
        text.autoresizingMask = .width
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.onCommit = { [weak self] in self?.commit() }
        text.onChange = { [weak self] in self?.dimComments() }
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        let hint = NSTextField.label(
            String(localized: "Lines starting with # are left out. ⌘↩ commits."), font: .ui(TextSize.caption),
            color: .secondaryLabelColor)
        let cancel = ClosureButton(title: String(localized: "Cancel")) { [weak self] in self?.dismiss() }
        cancel.bezelStyle = .push
        cancel.toolTip = String(localized: "Close without committing")
        commitButton.title =
            amend ? String(localized: "Amend") : push ? String(localized: "Commit & Push") : String(localized: "Commit")
        commitButton.bezelStyle = .push
        commitButton.bezelColor = .controlAccentColor
        commitButton.toolTip = String(localized: "Commit (⌘↩)")
        commitButton.target = self
        commitButton.action = #selector(commitPressed)
        let bar = NSStackView(views: [hint, NSView(), cancel, commitButton])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let sep = NSBox()
        sep.boxType = .separator
        root.pin(stacked(bar, sep, scroll))
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 40), sep.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    /// The message (the last commit's, when amending), then what goes into the commit as "#" lines, as git's own template does.
    private func fill(_ message: String) async {
        // The "#" lines only describe the commit; without them the message is still the message.
        let changes = await app.quiet(GitStatus(id: worktreeId)) ?? []
        let branch = await app.quiet(GitBranches(id: worktreeId))?.current
        let staged = changes.filter { $0.staged && !$0.conflicted }
        let files = staged.isEmpty ? changes.filter { !$0.conflicted } : staged
        var lines = [message, ""]
        lines.append(
            files.isEmpty
                ? "# No changes to commit."
                : (staged.isEmpty ? "# All changes" : "# Staged changes")
                    + (branch.map { String(localized: " on “\($0)”") } ?? "") + ":")
        lines += files.map {
            "#\t" + SourceControlController.letter($0, staged.isEmpty ? .changes : .staged).0 + "  " + $0.path
        }
        text.string = lines.joined(separator: "\n")
        text.setSelectedRange(NSRange(location: (message as NSString).length, length: 0))
        dimComments()
        focus()
    }

    private func dimComments() {
        guard let ts = text.textStorage else { return }
        let all = NSRange(location: 0, length: ts.length)
        ts.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        (ts.string as NSString).enumerateSubstrings(in: all, options: .byLines) { line, r, _, _ in
            if line?.hasPrefix("#") == true {
                ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            }
        }
    }

    @objc private func commitPressed() { commit() }

    private func commit() {
        let message = text.string.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, commitButton.isEnabled else {
            NSSound.beep()
            return
        }
        commitButton.isEnabled = false
        Task {
            let result = await GitCommit.run(app, worktreeId, message: message, push: push, amend: amend)
            if result.pushed { Banner.show(String(localized: "Pushed")) }
            if result.committed { dismiss() }
            commitButton.isEnabled = true
        }
    }

    private func dismiss() { app.workbench.closeTab(uri: uri, remember: false) }
    func focus() { text.window?.makeFirstResponder(text) }
}

/// Commits what's staged, or every change, new files too, when nothing is (VS Code's smart commit), then pushes if asked.
/// Failures go to the banner, where an agent can be asked to fix them.
@MainActor
enum GitCommit {
    /// Nothing staged: the commit takes every change. A list cut at its limit can have left out what's staged, so it doesn't then.
    static func takesEverything(_ changes: [FileChange]) -> Bool {
        changes.count < FileChange.limit && !changes.contains { $0.staged && !$0.conflicted }
    }

    /// A commit that went in and a push that didn't are two results: the one who asked says what's left.
    static func run(_ app: AppModel, _ wid: String, message: String, push: Bool, amend: Bool) async -> (
        committed: Bool, pushed: Bool
    ) {
        // Unread, nothing would look staged and every change would go in: stop with the banner instead.
        guard let changes = await app.call(GitStatus(id: wid)) else { return (false, false) }
        let result = await app.tryCall(
            Core.GitCommit(id: wid, message: message, all: takesEverything(changes), amend: amend))   // this enum's namesake
        if let error = result.error {
            GitFix(app).offer(error, recipe: "fixCommit", worktree: wid)
            return (false, false)
        }
        guard push else { return (true, false) }
        // The app's one push: the branch chip says "Pushing…", and CI is looked for.
        let refused = await GitSync.run(app, wid, ["push"])
        if let refused { GitFix(app).offer(refused, recipe: "fixPush", worktree: wid) }
        return (true, refused == nil)
    }
}
