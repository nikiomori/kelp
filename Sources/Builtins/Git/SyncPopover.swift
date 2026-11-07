import AppKit
import Core
import DesignKit
import KelpKit

/// What the branch chip opens: one line on where the branch stands against its upstream, the one sync that matters, the
/// commits it would move, and a line to commit what's changed. Everything bigger (staging, history, diffs) stays in Source Control.
@MainActor
final class SyncPopover: NSViewController {
    private static let width: CGFloat = 320, shown = 5   // a popover of commits, as the commit card
    private static let captionAttributes: [NSAttributedString.Key: Any] =
        [.font: NSFont.ui(11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]

    private let app: AppModel
    private let wid: String
    weak var popover: NSPopover?

    private let name = PointerButton(frame: .zero), state = NSTextField(labelWithString: "")
    private lazy var fetch = PointerButton(title: String(localized: "Fetch")) { [weak self] in self?.sync(["fetch"]) }
    private lazy var primary = ClosureButton(title: "") { [weak self] in self.map { $0.sync($0.primaryOps) } }
    private lazy var commit = ClosureButton(title: String(localized: "Commit")) { [weak self] in self?.commitPressed() }
    private let busy = NSProgressIndicator(), note = NSTextField(wrappingLabelWithString: ""), status = NSStackView()
    private let outgoing = NSStackView(), incoming = NSStackView(), ci = NSStackView()
    /// The folder whose CI the section shows (a workspace shares its project's): the one the branch chip's mark reads.
    private var folder: String { app.gitFolder(of: wid)?.id ?? wid }
    private let changes = NSTextField(labelWithString: ""), stats = NSTextField(labelWithString: ""),
        message = NSTextField()
    private let nothing = NSTextField(labelWithString: String(localized: "Nothing to commit"))
    private let hint = NSTextField(labelWithString: String(localized: "⏎ commit · ⌘⏎ commit and push"))
    private let field = NSStackView()
    private let root = NSStackView()

    private var unsynced: Unsynced?
    private var listKey = ""
    private var result: (text: String, failed: Bool, rejected: Bool)?
    private var primaryOps: [String] = []
    private var showIncoming = false, committing = false

    init(app: AppModel, worktree: String) {
        self.app = app
        wid = worktree
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    override func loadView() {
        name.padding = 4
        name.imagePosition = .imageTrailing
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        name.target = self
        name.action = #selector(switchMenu)
        name.toolTip = String(localized: "Switch Branch")
        state.font = .ui(12)
        state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingMiddle
        state.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        fetch.padding = 4
        fetch.image = .symbol("arrow.down.to.line", String(localized: "Fetch"))   // as Source Control's
        fetch.symbolConfiguration = .chrome()
        fetch.imagePosition = .imageLeading
        fetch.attributedTitle = NSAttributedString(
            string: fetch.title,
            attributes: [.font: NSFont.ui(12), .foregroundColor: NSColor.secondaryLabelColor])
        fetch.contentTintColor = .secondaryLabelColor
        fetch.toolTip = String(localized: "Fetch from the remote")
        let head = NSStackView()
        head.alignment = .top
        head.setViews([column([name, state], spacing: 2)], in: .leading)
        head.setViews([fetch], in: .trailing)

        // The popover's one action, in words alone and the accent (macOS 26's primary tint; the bezel colour before it).
        primary.bezelStyle = .push
        primary.controlSize = .large
        if #available(macOS 26, *) {
            primary.tintProminence = .primary
        } else {
            primary.bezelColor = .controlAccentColor
        }

        busy.style = .spinning
        busy.controlSize = .small
        note.font = .ui(12)
        note.maximumNumberOfLines = 4
        note.preferredMaxLayoutWidth = Self.width - 22
        status.setViews([busy, note], in: .top)
        status.spacing = 6
        status.alignment = .top

        for stack in [outgoing, incoming, ci] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
        }

        let changeHead = NSStackView()
        changeHead.setViews([changes], in: .leading)
        changeHead.setViews([stats], in: .trailing)
        message.placeholderString = String(localized: "Commit message")
        message.delegate = self
        message.target = self
        message.action = #selector(commitPressed)
        field.setViews([message, commit], in: .leading)
        field.spacing = 8
        nothing.font = .ui(12)
        nothing.textColor = .secondaryLabelColor
        hint.font = .ui(11)
        hint.textColor = .tertiaryLabelColor

        // The whole line is the link, its chevron too: it greys in under the pointer and springs when clicked.
        let footer = LinkRow(String(localized: "Open Source Control")) { [weak self] in
            self?.app.workbench.showPanel("git.changes")
            self?.popover?.performClose(nil)
        }

        let rules = (rule(), rule())
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 8, right: 14)
        root.setViews(
            [
                head, status, primary, ci, outgoing, incoming, rules.0, changeHead, field, nothing, hint, rules.1,
                footer
            ], in: .top)
        let gaps: [(NSView, CGFloat)] = [
            (head, 12), (primary, 16), (ci, 12), (outgoing, 12), (incoming, 16), (rules.0, 12), (field, 6), (hint, 12),
            (rules.1, 4)
        ]
        for (part, gap) in gaps {
            root.setCustomSpacing(gap, after: part)
        }
        for part in [head, status, primary, changeHead, field, footer] as [NSView] {
            part.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        }

        view = Self.ground(root)
    }

    /// The popover material under the glass, as Quick Open and the switcher have it: code scrolling behind the popover
    /// shouldn't tint what's written here.
    private static func ground(_ content: NSView) -> NSView {
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .withinWindow
        fx.state = .active
        fx.pin(content)
        return fx
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [app, wid] in
            app.latest(GitEvent.self, wid)
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [app, wid] in
            GitSync.state(app).running[wid]
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [weak self] in
            self.flatMap { $0.app.latest(CIEvent.self, $0.folder) }
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [app] in
            app.settings[SettingKeys.ciPopover]
        } changed: { [weak self] _ in
            self?.update()
        }
    }

    /// Opened for a pull or a push, not to type: the commit field waits for a click.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        return stack
    }

    private func rule() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return line
    }

    private func label(_ text: String, size: CGFloat = 12, secondary: Bool = true) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .ui(size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    // MARK: state

    private func update() {
        let info = app.latest(GitEvent.self, wid)?.branches, running = GitSync.state(app).running[wid]
        let ahead = info?.ahead ?? 0, behind = info?.behind ?? 0, published = info?.upstream != nil
        let hasRemote = published || !(info?.remote.isEmpty ?? true)
        name.attributedTitle = NSAttributedString(
            string: info?.current ?? info?.head ?? "HEAD",
            attributes: [.font: NSFont.ui(15, weight: .semibold), .foregroundColor: NSColor.labelColor])
        name.image = .symbol("chevron.down", String(localized: "Switch Branch"))
        name.isEnabled = info != nil && running == nil
        state.stringValue = Self.standing(upstream: info?.upstream, ahead: ahead, behind: behind, hasRemote: hasRemote)

        fetch.isHidden = !hasRemote
        fetch.isEnabled = running == nil
        showPrimary(
            ahead: ahead, behind: behind, published: published, possible: hasRemote && info?.current != nil,
            running: running)
        showStatus(running)
        loadLists(info)
        showLists(ahead: ahead, behind: behind, published: published)
        showCI(on: info?.upstream ?? info?.current)
        showChanges()
        preferredContentSize = view.fittingSize
    }

    /// Where the branch stands, in one line.
    private static func standing(upstream: String?, ahead: Int, behind: Int, hasRemote: Bool) -> String {
        guard let upstream else {
            return hasRemote
                ? String(localized: "Not on a remote yet") : String(localized: "No remote — add one in Source Control")
        }
        switch (ahead, behind) {
        case (0, 0): return String(localized: "Up to date with \(upstream)")
        case (_, 0):
            return ahead == 1
                ? String(localized: "1 commit ahead of \(upstream)")
                : String(localized: "\(ahead) commits ahead of \(upstream)")
        case (0, _):
            return behind == 1
                ? String(localized: "1 commit behind \(upstream)")
                : String(localized: "\(behind) commits behind \(upstream)")
        default: return String(localized: "\(ahead) ahead, \(behind) behind \(upstream)")
        }
    }

    /// The one sync that matters now, full width; none when there's nothing to move. A rejected push turns it into the fix.
    private func showPrimary(ahead: Int, behind: Int, published: Bool, possible: Bool, running: String?) {
        let (title, ops) = Self.action(
            ahead: ahead, behind: behind, published: published, rejected: result?.rejected == true)
        primaryOps = ops
        primary.isHidden = !possible || ops.isEmpty
        let text = running ?? title
        primary.title = text
        primary.font = .ui(13, weight: .semibold)
        primary.isEnabled = running == nil
    }

    private static func action(ahead: Int, behind: Int, published: Bool, rejected: Bool) -> (String, [String]) {
        if !published { return (String(localized: "Publish Branch"), ["push"]) }
        if rejected || (ahead > 0 && behind > 0) {
            let title =
                behind > 0
                ? String(localized: "Pull \(behind), then push \(ahead)") : String(localized: "Pull, then push")
            return (title, ["pull", "push"])
        }
        if behind > 0 {
            return (
                behind == 1 ? String(localized: "Pull 1 commit") : String(localized: "Pull \(behind) commits"), ["pull"]
            )
        }
        if ahead > 0 {
            return (
                ahead == 1 ? String(localized: "Push 1 commit") : String(localized: "Push \(ahead) commits"), ["push"]
            )
        }
        return ("", [])
    }

    private func showStatus(_ running: String?) {
        let inButton = running != nil && !primary.isHidden
        busy.isHidden = running == nil || inButton
        if let running {
            busy.startAnimation(nil)
            note.stringValue = inButton ? "" : running
            note.textColor = .secondaryLabelColor
        } else {
            busy.stopAnimation(nil)
            note.stringValue = result?.text ?? ""
            note.textColor = result?.failed == true ? .textRed : .textGreen
        }
        note.isHidden = note.stringValue.isEmpty
        status.isHidden = note.isHidden
    }

    /// The commits behind the counts, read again when the head, the upstream or a count moves (a fetch, a commit, a push).
    private func loadLists(_ info: BranchInfo?) {
        guard let branch = info else { return }
        let key = "\(branch.head ?? "")|\(branch.upstream ?? "")|\(branch.ahead ?? -1)|\(branch.behind ?? -1)"
        guard key != listKey else { return }
        listKey = key
        Task {
            let lists = await app.quiet(GitUnsynced(id: wid, limit: Self.shown))
            guard key == listKey else { return }
            unsynced = lists
            update()
        }
    }

    private func showLists(ahead: Int, behind: Int, published: Bool) {
        let out = unsynced?.outgoing ?? [], inc = unsynced?.incoming ?? []
        outgoing.isHidden = ahead == 0
        incoming.isHidden = behind == 0

        let title = published ? String(localized: "To push") : String(localized: "To publish")
        outgoing.setViews(
            [caption(title, ahead)] + out.map { row($0, trailing: when($0)) } + more(ahead - out.count), in: .top)

        let toggle = PointerButton(title: "") { [weak self] in
            guard let self else { return }
            showIncoming.toggle()
            update()
        }
        toggle.radius = Metrics.radiusXS
        toggle.padding = 2
        toggle.attributedTitle = NSAttributedString(
            string: String(localized: "To pull") + " · \(behind)", attributes: Self.captionAttributes)
        toggle.image = .symbol(showIncoming ? "chevron.down" : "chevron.right", String(localized: "To pull"))
        toggle.imagePosition = .imageLeading
        toggle.contentTintColor = .secondaryLabelColor
        let rows = showIncoming ? inc.map { row($0, trailing: $0.author) } + more(behind - inc.count) : []
        incoming.setViews([toggle] + rows, in: .top)
    }

    /// "CI · origin/main" and the newest run of each workflow (CI and deploys apart), as CI Runs marks them; a row opens
    /// CI Runs, which has the logs and Re-run. Settings › Appearance › CI can leave it out.
    private func showCI(on branch: String?) {
        let runs =
            !app.settings[SettingKeys.ciPopover]
            ? [] : CIRuns.latest(app.latest(CIEvent.self, folder)?.result?.runs ?? [])
        ci.isHidden = runs.isEmpty
        guard !runs.isEmpty else { return }
        let head = NSTextField(labelWithString: "")
        head.attributedStringValue = NSAttributedString(
            string: ["CI", branch].compactMap { $0 }.joined(separator: " · "), attributes: Self.captionAttributes)
        let shown = runs.prefix(3).map { run in
            let words = label(CIRunLook.words(run.status, run.conclusion))
            words.lineBreakMode = .byTruncatingTail
            words.setContentCompressionResistancePriority(.init(240), for: .horizontal)
            let name = label(run.workflow, secondary: false)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            let line = LinkRow(
                [
                    CIRunLook.mark(run.status, run.conclusion), name, words, NSView(),
                    label(CIRunLook.ago(run.began), size: 11)
                ],
                said: "\(run.workflow): \(CIRunLook.words(run.status, run.conclusion))"
            ) { [weak self] in
                guard let self else { return }
                RowMarks.of(app).openCI(folder)
                popover?.performClose(nil)
            }
            line.toolTip = run.title + "\n" + String(localized: "Click to open CI Runs")
            line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
            return line as NSView
        }
        ci.setViews([head] + shown + more(runs.count - shown.count), in: .top)
        ci.setCustomSpacing(2, after: head)
    }

    private func caption(_ text: String, _ count: Int) -> NSView {
        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = NSAttributedString(
            string: text + " · \(count)", attributes: Self.captionAttributes)
        return field
    }

    /// "11m", as the sidebar and the graph write how long ago (the relative formatter's short style wrote "−11 мин" in Russian).
    private func when(_ commit: Unsynced.Commit) -> String { shortAgo(Date(timeIntervalSince1970: commit.date)) }

    private func more(_ count: Int) -> [NSView] { count > 0 ? [label(String(localized: "and \(count) more"))] : [] }

    private func row(_ commit: Unsynced.Commit, trailing: String) -> NSView {
        let hash = label(commit.hash, size: 11)
        hash.font = .monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular)
        let subject = label(commit.subject, secondary: false)
        subject.lineBreakMode = .byTruncatingTail
        subject.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let line = NSStackView(views: [hash, subject, label(trailing, size: 11)])
        line.spacing = 8
        hash.widthAnchor.constraint(equalToConstant: 56).isActive = true
        line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return line
    }

    private func showChanges() {
        let git = app.latest(GitEvent.self, wid), list = git?.changes ?? [], changed = list.count
        let hasRemote = git?.branches.map { $0.upstream != nil || !$0.remote.isEmpty } ?? false
        changes.attributedStringValue = NSAttributedString(
            string: String(localized: "Changes") + (changed > 0 ? " · \(changed)" : ""),
            attributes: Self.captionAttributes)
        let text = NSMutableAttributedString()
        if changed > 0, let totals = git?.stats {
            let mono = NSFont.monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular)
            for (count, sign, color) in [
                (totals.totalAdded, "+", NSColor.textGreen), (totals.totalRemoved, "−", .textRed)
            ]
            where count > 0 {
                text.append(
                    NSAttributedString(
                        string: (text.length > 0 ? "  " : "") + "\(sign)\(count)",
                        attributes: [.font: mono, .foregroundColor: color]))
            }
        }
        stats.attributedStringValue = text
        field.isHidden = changed == 0
        nothing.isHidden = changed > 0
        hint.isHidden = changed == 0 || !hasRemote
        let blocked = list.contains(where: \.conflicted) || GitSync.state(app).running[wid] != nil || committing
        commit.isEnabled = !message.stringValue.trimmingCharacters(in: .whitespaces).isEmpty && !blocked
        message.isEnabled = !committing
    }

    // MARK: actions

    private func sync(_ ops: [String]) {
        guard GitSync.state(app).running[wid] == nil else { return }
        let before = app.latest(GitEvent.self, wid)?.branches, ahead = before?.ahead ?? 0, behind = before?.behind ?? 0
        let published = before?.upstream != nil, branch = before?.current ?? "HEAD"
        result = nil
        Task {
            if let error = await GitSync.run(app, wid, ops) {
                failed(error, ops: ops)
            } else if ops.contains("push") {
                let text =
                    !published
                    ? String(localized: "Published \(branch).")
                    : ahead == 1
                        ? String(localized: "Pushed 1 commit.") : String(localized: "Pushed \(max(ahead, 1)) commits.")
                result = (text, false, false)
            } else if ops.contains("pull") {
                result = (
                    behind == 1
                        ? String(localized: "Pulled 1 commit.") : String(localized: "Pulled \(behind) commits."), false,
                    false
                )
            }
            update()
        }
    }

    /// A pull that stopped on conflicts is work for the agent (and for Source Control); anything else says why, here.
    private func failed(_ error: String, ops: [String]) {
        guard ops.contains("pull"), error.lowercased().contains("conflict") else {
            result = (Self.summary(error), true, GitSync.isRejected(error))
            return
        }
        popover?.performClose(nil)
        GitFix(app).offer(
            error, recipe: "resolveConflicts", worktree: wid,
            vars: ["base": String(localized: "the remote branch"), "files": String(localized: "see git status")])
        app.workbench.showPanel("git.changes")
    }

    /// Git's message in a few lines: the pieces of a long push or pull report that say why.
    private static func summary(_ error: String) -> String {
        if GitSync.isRejected(error) {
            return String(localized: "Push rejected: the remote has commits this branch doesn't. Pull first.")
        }
        let lines = error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty
        }
        let useful = lines.filter { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
        return (useful.isEmpty ? lines : useful).prefix(3).joined(separator: "\n")
            .replacingOccurrences(of: "fatal: ", with: "").replacingOccurrences(of: "error: ", with: "")
    }

    @objc private func commitPressed() { commitAll(thenPush: false) }

    /// ⌘⏎ in the field: commit, then push (or publish) what's now ahead.
    private func commitAll(thenPush: Bool) {
        let text = message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.isEnabled, !text.isEmpty else { return }
        committing = true
        update()
        Task {
            defer {
                committing = false
                app.watchAgain(.git, wid)
                update()
            }
            // Source Control's commit, the one way to commit: what's staged, else every change; a failure offers a fix.
            guard await GitCommit.run(app, wid, message: text, push: false, amend: false).committed else { return }
            message.stringValue = ""
            if thenPush {
                committing = false
                sync(["push"])
            }
        }
    }

    /// The local branches to switch to, and a new one; the remote ones are in Source Control.
    @objc private func switchMenu() {
        guard let info = app.latest(GitEvent.self, wid)?.branches else { return }
        let menu = NSMenu(), wid = wid
        for branch in info.local {
            menu.add(branch) { [weak self] in self?.switchBranch(GitSwitch(id: wid, branch: branch)) }.state =
                branch == info.current ? .on : .off
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Create Branch…")) { [weak self] in
            Task {
                let starts = String(localized: "Starts from \(info.current ?? "HEAD") and switches to it.")
                guard let name = await prompt(String(localized: "Create Branch"), starts), !name.isEmpty else { return }
                self?.switchBranch(GitSwitch(id: wid, branch: name, create: true))
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: name.bounds.height + 4), in: name)
    }

    private func switchBranch(_ request: GitSwitch) {
        Task {
            await app.call(request)
            app.watchAgain(.git, request.id)   // the chip now, not on the next file event
        }
    }
}

extension SyncPopover: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) { showChanges() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) || sel == Selector(("noop:")),
            let event = NSApp.currentEvent, event.keyCode == 36 || event.keyCode == 76,
            event.modifierFlags.contains(.command)
        else { return false }
        if commit.isEnabled { commitAll(thenPush: true) }
        return true
    }
}

/// A line that is a link to somewhere else ("Open Source Control ›"): words on the left, a chevron on the right, the
/// whole line one target that answers the pointer (`PointerControl`).
@MainActor
private final class LinkRow: PointerControl {
    private let run: () -> Void
    convenience init(_ title: String, action: @escaping () -> Void) {
        let label = NSTextField(labelWithString: title)
        label.font = .ui(13)
        self.init([label, NSView()], said: title, action: action)
    }
    /// `views` along the row, then the chevron; `said` is what VoiceOver reads for it.
    init(_ views: [NSView], said: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        layer?.cornerRadius = Metrics.radiusSM
        let chevron = NSImageView(image: .symbol("chevron.right", ""))
        chevron.contentTintColor = .tertiaryLabelColor
        let row = NSStackView(views: views + [chevron])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        pin(row)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(said)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func clicked() { run() }
    // one target, label included
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}
