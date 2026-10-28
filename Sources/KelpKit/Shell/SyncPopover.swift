import AppKit
import Core
import DesignKit

/// What the branch chip opens: one line on where the branch stands against its upstream, the one sync that matters, the
/// commits it would move, and a line to commit what's changed. Everything bigger (staging, history, diffs) stays in Source Control.
@MainActor
final class SyncPopover: NSViewController {
    private static let width: CGFloat = 332, shown = 5
    private static let times: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private static let captionAttributes: [NSAttributedString.Key: Any] =
        [.font: NSFont.ui(11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.4]

    private let app: AppModel
    private let wid: String
    weak var popover: NSPopover?

    private let name = NSButton(title: "", target: nil, action: nil), state = NSTextField(labelWithString: "")
    private lazy var fetch = ClosureButton(title: String(localized: "Fetch")) { [weak self] in self?.sync(["fetch"]) }
    private lazy var primary = ClosureButton(title: "") { [weak self] in self.map { $0.sync($0.primaryOps) } }
    private lazy var commit = ClosureButton(title: String(localized: "Commit")) { [weak self] in self?.commitPressed() }
    private let busy = NSProgressIndicator(), note = NSTextField(wrappingLabelWithString: ""), status = NSStackView()
    private let outgoing = NSStackView(), incoming = NSStackView()
    private let changes = NSTextField(labelWithString: ""), stats = NSTextField(labelWithString: ""), message = NSTextField()
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
        name.isBordered = false
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
        fetch.isBordered = false
        fetch.image = .symbol("arrow.clockwise", String(localized: "Fetch"))
        fetch.imagePosition = .imageLeading
        fetch.attributedTitle = NSAttributedString(string: fetch.title,
                                                   attributes: [.font: NSFont.ui(12), .foregroundColor: NSColor.secondaryLabelColor])
        fetch.contentTintColor = .secondaryLabelColor
        fetch.toolTip = String(localized: "Fetch from the remote")
        let head = NSStackView()
        head.alignment = .top
        head.setViews([column([name, state], spacing: 2)], in: .leading)
        head.setViews([fetch], in: .trailing)

        primary.bezelStyle = .push
        primary.controlSize = .large
        primary.imagePosition = .imageLeading
        primary.imageHugsTitle = true
        primary.bezelColor = .controlAccentColor
        primary.contentTintColor = .white

        busy.style = .spinning
        busy.controlSize = .small
        note.font = .ui(12)
        note.maximumNumberOfLines = 4
        note.preferredMaxLayoutWidth = Self.width - 22
        status.setViews([busy, note], in: .top)
        status.spacing = 6
        status.alignment = .top

        for s in [outgoing, incoming] {
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 2
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

        let open = ClosureButton(title: String(localized: "Open Source Control")) { [weak self] in
            self?.app.workbench.showPanel("git.changes")
            self?.popover?.performClose(nil)
        }
        open.isBordered = false
        open.attributedTitle = NSAttributedString(string: open.title, attributes: [.font: NSFont.ui(13), .foregroundColor: NSColor.labelColor])
        let chevron = NSImageView(image: .symbol("chevron.right", ""))
        chevron.contentTintColor = .tertiaryLabelColor
        let footer = NSStackView()
        footer.setViews([open], in: .leading)
        footer.setViews([chevron], in: .trailing)

        let rules = (rule(), rule())
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 8, right: 14)
        root.setViews([head, status, primary, outgoing, incoming, rules.0, changeHead, field, nothing, hint, rules.1, footer], in: .top)
        let gaps: [(NSView, CGFloat)] = [(head, 12), (primary, 16), (outgoing, 12), (incoming, 16), (rules.0, 12), (field, 6), (hint, 12), (rules.1, 4)]
        for (v, gap) in gaps {
            root.setCustomSpacing(gap, after: v)
        }
        for v in [head, status, primary, changeHead, field, footer] as [NSView] { v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true }

        view = Self.ground(root)
    }

    /// A denser ground than the popover's glass: code scrolling behind it shouldn't tint what's written here.
    private static func ground(_ content: NSView) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 0
        box.contentViewMargins = .zero
        box.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6)
        box.contentView = content
        return box
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [app, wid] in app.git[wid] } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app, wid] in app.syncing[wid] } changed: { [weak self] _ in self?.update() }
    }

    /// Opened for a pull or a push, not to type: the commit field waits for a click.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        return s
    }

    private func rule() -> NSView {
        let r = NSBox()
        r.boxType = .separator
        r.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return r
    }

    private func label(_ text: String, size: CGFloat = 12, secondary: Bool = true) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .ui(size)
        l.textColor = secondary ? .secondaryLabelColor : .labelColor
        return l
    }

    // MARK: state

    private func update() {
        let info = app.git[wid]?.branches, running = app.syncing[wid]
        let ahead = info?.ahead ?? 0, behind = info?.behind ?? 0, published = info?.upstream != nil
        let hasRemote = published || !(info?.remote.isEmpty ?? true)
        name.attributedTitle = NSAttributedString(string: info?.current ?? info?.head ?? "HEAD",
                                                  attributes: [.font: NSFont.ui(15, weight: .semibold), .foregroundColor: NSColor.labelColor])
        name.image = .symbol("chevron.down", String(localized: "Switch Branch"))
        name.isEnabled = info != nil && running == nil
        state.stringValue = Self.standing(upstream: info?.upstream, ahead: ahead, behind: behind, hasRemote: hasRemote)

        fetch.isHidden = !hasRemote
        fetch.isEnabled = running == nil
        showPrimary(ahead: ahead, behind: behind, published: published, possible: hasRemote && info?.current != nil, running: running)
        showStatus(running)
        loadLists(info)
        showLists(ahead: ahead, behind: behind, published: published)
        showChanges()
        preferredContentSize = view.fittingSize
    }

    /// Where the branch stands, in one line.
    private static func standing(upstream: String?, ahead: Int, behind: Int, hasRemote: Bool) -> String {
        guard let upstream else { return hasRemote ? String(localized: "Not on a remote yet") : String(localized: "No remote — add one in Source Control") }
        switch (ahead, behind) {
        case (0, 0): return String(localized: "Up to date with \(upstream)")
        case (_, 0): return ahead == 1 ? String(localized: "1 commit ahead of \(upstream)") : String(localized: "\(ahead) commits ahead of \(upstream)")
        case (0, _): return behind == 1 ? String(localized: "1 commit behind \(upstream)") : String(localized: "\(behind) commits behind \(upstream)")
        default: return String(localized: "\(ahead) ahead, \(behind) behind \(upstream)")
        }
    }

    /// The one sync that matters now, full width; none when there's nothing to move. A rejected push turns it into the fix.
    private func showPrimary(ahead: Int, behind: Int, published: Bool, possible: Bool, running: String?) {
        let (title, symbol, ops) = Self.action(ahead: ahead, behind: behind, published: published, rejected: result?.rejected == true)
        primaryOps = ops
        primary.isHidden = !possible || ops.isEmpty
        let text = running ?? title
        primary.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.white, .font: NSFont.ui(13, weight: .semibold)])
        primary.image = .symbol(running == nil ? symbol : "arrow.triangle.2.circlepath", text)
        primary.isEnabled = running == nil
    }

    private static func action(ahead: Int, behind: Int, published: Bool, rejected: Bool) -> (String, String, [String]) {
        if !published { return (String(localized: "Publish Branch"), "icloud.and.arrow.up", ["push"]) }
        if rejected || (ahead > 0 && behind > 0) {
            let title = behind > 0 ? String(localized: "Pull \(behind), then push \(ahead)") : String(localized: "Pull, then push")
            return (title, "arrow.up.arrow.down", ["pull", "push"])
        }
        if behind > 0 { return (behind == 1 ? String(localized: "Pull 1 commit") : String(localized: "Pull \(behind) commits"), "arrow.down", ["pull"]) }
        if ahead > 0 { return (ahead == 1 ? String(localized: "Push 1 commit") : String(localized: "Push \(ahead) commits"), "arrow.up", ["push"]) }
        return ("", "", [])
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
            note.textColor = result?.failed == true ? .systemRed : .systemGreen
        }
        note.isHidden = note.stringValue.isEmpty
        status.isHidden = note.isHidden
    }

    /// The commits behind the counts, read again when the head, the upstream or a count moves (a fetch, a commit, a push).
    private func loadLists(_ info: BranchInfo?) {
        guard let b = info else { return }
        let key = "\(b.head ?? "")|\(b.upstream ?? "")|\(b.ahead ?? -1)|\(b.behind ?? -1)"
        guard key != listKey else { return }
        listKey = key
        Task {
            let u = await app.quiet(GitUnsynced(id: wid, limit: Self.shown))
            guard key == listKey else { return }
            unsynced = u
            update()
        }
    }

    private func showLists(ahead: Int, behind: Int, published: Bool) {
        let out = unsynced?.outgoing ?? [], inc = unsynced?.incoming ?? []
        outgoing.isHidden = ahead == 0
        incoming.isHidden = behind == 0

        let title = published ? String(localized: "To push") : String(localized: "To publish")
        outgoing.setViews([caption(title, ahead)] + out.map { row($0, trailing: when($0)) } + more(ahead - out.count), in: .top)

        let toggle = ClosureButton(title: "") { [weak self] in
            guard let self else { return }
            showIncoming.toggle()
            update()
        }
        toggle.isBordered = false
        toggle.attributedTitle = NSAttributedString(string: String(localized: "To pull").uppercased() + " · \(behind)", attributes: Self.captionAttributes)
        toggle.image = .symbol(showIncoming ? "chevron.down" : "chevron.right", String(localized: "To pull"))
        toggle.imagePosition = .imageLeading
        toggle.contentTintColor = .secondaryLabelColor
        let rows = showIncoming ? inc.map { row($0, trailing: $0.author) } + more(behind - inc.count) : []
        incoming.setViews([toggle] + rows, in: .top)
    }

    private func caption(_ text: String, _ n: Int) -> NSView {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: text.uppercased() + " · \(n)", attributes: Self.captionAttributes)
        return l
    }

    private func when(_ c: Unsynced.Commit) -> String {
        Self.times.localizedString(for: Date(timeIntervalSince1970: c.date), relativeTo: Date())
    }

    private func more(_ n: Int) -> [NSView] { n > 0 ? [label(String(localized: "and \(n) more"))] : [] }

    private func row(_ c: Unsynced.Commit, trailing: String) -> NSView {
        let hash = label(c.hash, size: 11)
        hash.font = .monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular)
        let subject = label(c.subject, secondary: false)
        subject.lineBreakMode = .byTruncatingTail
        subject.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let r = NSStackView(views: [hash, subject, label(trailing, size: 11)])
        r.spacing = 8
        hash.widthAnchor.constraint(equalToConstant: 56).isActive = true
        r.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return r
    }

    private func showChanges() {
        let git = app.git[wid], list = git?.changes ?? [], n = list.count
        let hasRemote = git?.branches.map { $0.upstream != nil || !$0.remote.isEmpty } ?? false
        changes.attributedStringValue = NSAttributedString(string: String(localized: "Changes").uppercased() + (n > 0 ? " · \(n)" : ""),
                                                           attributes: Self.captionAttributes)
        let text = NSMutableAttributedString()
        if n > 0, let s = git?.stats {
            let mono = NSFont.monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular)
            for (count, sign, color) in [(s.totalAdded, "+", NSColor.systemGreen), (s.totalRemoved, "−", .systemRed)] where count > 0 {
                text.append(NSAttributedString(string: (text.length > 0 ? "  " : "") + "\(sign)\(count)", attributes: [.font: mono, .foregroundColor: color]))
            }
        }
        stats.attributedStringValue = text
        field.isHidden = n == 0
        nothing.isHidden = n > 0
        hint.isHidden = n == 0 || !hasRemote
        let blocked = list.contains(where: \.conflicted) || app.syncing[wid] != nil || committing
        commit.isEnabled = !message.stringValue.trimmingCharacters(in: .whitespaces).isEmpty && !blocked
        message.isEnabled = !committing
    }

    // MARK: actions

    private func sync(_ ops: [String]) {
        guard app.syncing[wid] == nil else { return }
        let before = app.git[wid]?.branches, ahead = before?.ahead ?? 0, behind = before?.behind ?? 0
        let published = before?.upstream != nil, branch = before?.current ?? "HEAD"
        result = nil
        Task {
            if let error = await GitSync.run(app, wid, ops) {
                failed(error, ops: ops)
            } else if ops.contains("push") {
                let text = !published ? String(localized: "Published \(branch).")
                    : ahead == 1 ? String(localized: "Pushed 1 commit.") : String(localized: "Pushed \(max(ahead, 1)) commits.")
                result = (text, false, false)
            } else if ops.contains("pull") {
                result = (behind == 1 ? String(localized: "Pulled 1 commit.") : String(localized: "Pulled \(behind) commits."), false, false)
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
        GitFix(app).offer(error, recipe: "resolveConflicts", worktree: wid,
                          vars: ["base": String(localized: "the remote branch"), "files": String(localized: "see git status")])
        app.workbench.showPanel("git.changes")
    }

    /// Git's message in a few lines: the pieces of a long push or pull report that say why.
    private static func summary(_ error: String) -> String {
        if GitSync.isRejected(error) { return String(localized: "Push rejected: the remote has commits this branch doesn't. Pull first.") }
        let lines = error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
            // Read now, not from the last push: unread, nothing would look staged and every change would go in.
            guard let status = await app.call(GitStatus(id: wid)) else { return }
            let all = !status.contains { $0.staged && !$0.conflicted }
            let r = await app.tryCall(GitCommit(id: wid, message: text, all: all))
            if let e = r.error { GitFix(app).offer(e, recipe: "fixCommit", worktree: wid); return }
            message.stringValue = ""
            if thenPush {
                committing = false
                sync(["push"])
            }
        }
    }

    /// The local branches to switch to, and a new one; the remote ones are in Source Control.
    @objc private func switchMenu() {
        guard let info = app.git[wid]?.branches else { return }
        let m = NSMenu(), wid = wid
        for b in info.local {
            m.add(b) { [weak self] in self?.switchBranch(GitSwitch(id: wid, branch: b)) }.state = b == info.current ? .on : .off
        }
        m.addItem(.separator())
        m.add(String(localized: "Create Branch…")) { [weak self] in
            Task {
                let starts = String(localized: "Starts from \(info.current ?? "HEAD") and switches to it.")
                guard let name = await prompt(String(localized: "Create Branch"), starts), !name.isEmpty else { return }
                self?.switchBranch(GitSwitch(id: wid, branch: name, create: true))
            }
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: name.bounds.height + 4), in: name)
    }

    private func switchBranch(_ m: GitSwitch) {
        Task {
            await app.call(m)
            app.watchAgain(.git, m.id)   // the chip now, not on the next file event
        }
    }
}

extension SyncPopover: NSTextFieldDelegate {
    func controlTextDidChange(_ n: Notification) { showChanges() }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) || sel == Selector(("noop:")),
              let e = NSApp.currentEvent, e.keyCode == 36 || e.keyCode == 76, e.modifierFlags.contains(.command) else { return false }
        if commit.isEnabled { commitAll(thenPush: true) }
        return true
    }
}
