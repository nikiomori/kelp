// What the sync popover shows: the branch's standing, its primary action, the commits and changes, CI.
import AppKit
import Core
import DesignKit
import KelpKit

extension SyncPopover {
    // MARK: state

    func update() {
        let info = app.latest(GitEvent.self, wid)?.branches, running = GitSync.state(app).running[wid]?.title
        let ahead = info?.ahead ?? 0, behind = info?.behind ?? 0, published = info?.upstream != nil
        let hasRemote = published || !(info?.remote.isEmpty ?? true)
        name.attributedTitle = NSAttributedString(
            string: info?.current ?? info?.head ?? "HEAD",
            attributes: [.font: NSFont.ui(TextSize.heading, weight: .semibold), .foregroundColor: NSColor.labelColor])
        name.image = .symbol("chevron.down", String(localized: "Switch Branch"))
        name.isEnabled = info != nil && running == nil
        state.stringValue =
            Self.standing(upstream: info?.upstream, ahead: ahead, behind: behind, hasRemote: hasRemote)
            + (unsynced?.fetched.map { " · " + Self.fetched(Date(timeIntervalSince1970: $0)) } ?? "")

        fetch.isHidden = !hasRemote
        fetch.isEnabled = running == nil
        showPrimary(
            ahead: ahead, behind: behind, published: published, possible: hasRemote && info?.current != nil,
            running: running)
        showStatus(running)
        loadLists(info)
        showLists(ahead: ahead, behind: behind, published: published)
        showCI()
        showChanges()
        fit()
    }

    /// The words' size and the popover's edges around them (its shadow margin and the arrow), known once it's shown.
    private func fit() {
        let size = root.fittingSize, edges = view.safeAreaInsets
        let wanted = NSSize(
            width: size.width + edges.left + edges.right, height: size.height + edges.top + edges.bottom)
        if preferredContentSize != wanted { preferredContentSize = wanted }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fit()
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

    /// "fetched 4m ago": how old the counts may be.
    private static func fetched(_ date: Date) -> String {
        let ago = shortAgo(date)
        return ago == String(localized: "now")
            ? String(localized: "fetched just now") : String(localized: "fetched \(ago) ago")
    }

    /// The one sync that matters now, full width; none when there's nothing to move. A rejected push turns it into the fix.
    private func showPrimary(ahead: Int, behind: Int, published: Bool, possible: Bool, running: String?) {
        let (title, ops) = Self.action(
            ahead: ahead, behind: behind, published: published, rejected: result?.rejected == true)
        primaryOps = ops
        primary.isHidden = !possible || ops.isEmpty
        let text = running ?? title
        primary.title = text
        primary.font = .ui(TextSize.body, weight: .semibold)
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

        // The button above says what the commits are: a caption only where two lists, or a first push, need telling
        // apart.
        let title = published ? String(localized: "To push") : String(localized: "To publish")
        let named = !published || behind > 0
        let mine = cut(out, of: ahead)
        outgoing.setViews(
            (named ? [caption(title, ahead)] : []) + mine.map { row($0, trailing: when($0)) }
                + more(ahead - mine.count), in: .top)
        if named, let head = outgoing.arrangedSubviews.first { outgoing.setCustomSpacing(4, after: head) }

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
        let theirs = cut(inc, of: behind)
        let rows = showIncoming ? theirs.map { row($0, trailing: $0.author) } + more(behind - theirs.count) : []
        incoming.setViews([toggle] + rows, in: .top)
    }

    /// The newest run of each workflow (CI and deploys apart), as CI Runs marks them, under the standing line: it is
    /// the remote's state. No caption: the mark and the workflow's name say it. A row opens CI Runs, which has the
    /// logs and Re-run. Settings › Appearance › CI can leave it out.
    private func showCI() {
        let runs =
            !app.settings[SettingKeys.ciPopover]
            ? [] : CIRuns.latest(app.latest(CIEvent.self, folder)?.result?.runs ?? [])
        ci.isHidden = runs.isEmpty
        root.setCustomSpacing(runs.isEmpty ? 12 : 4, after: state)
        guard !runs.isEmpty else { return }
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
            line.widthAnchor.constraint(equalToConstant: Self.width + 2 * Self.bleed).isActive = true
            return line as NSView
        }
        ci.setViews(shown + more(runs.count - shown.count), in: .top)
    }

    private func caption(_ text: String, _ count: Int) -> NSView {
        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = NSAttributedString(
            string: text + " · \(count)", attributes: Self.captionAttributes)
        return field
    }

    /// "11m", as the sidebar and the graph write how long ago (the relative formatter's short style wrote "−11 мин" in Russian).
    private func when(_ commit: Unsynced.Commit) -> String { shortAgo(Date(timeIntervalSince1970: commit.date)) }

    /// All of them when they fit in `shown` rows; past that one row fewer, so "and N more" counts at least two.
    private func cut(_ commits: [Unsynced.Commit], of count: Int) -> [Unsynced.Commit] {
        Array(commits.prefix(count > Self.shown ? Self.shown - 1 : Self.shown))
    }

    private func more(_ count: Int) -> [NSView] {
        guard count > 0 else { return [] }
        let line = label(String(localized: "and \(count) more"))
        line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return [line]
    }

    private func row(_ commit: Unsynced.Commit, trailing: String) -> NSView {
        let line = CommitRow(subject: commit.subject, hash: commit.hash, trailing: trailing)
        line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return line
    }

    /// The first few changed files, as Source Control lists them: the letter, the folder in grey, the name.
    private func showFiles(_ list: [FileChange]) {
        let shown = list.prefix(list.count > 3 ? 2 : 3).map { file -> NSView in
            let code = file.letter(inWorktree: file.unstaged || file.untracked)
            let letter = NSTextField(labelWithString: code)
            letter.font = .uiMono(TextSize.caption, weight: .semibold)
            letter.textColor = .gitLetter(code)
            letter.widthAnchor.constraint(equalToConstant: 10).isActive = true
            let name = NSTextField(labelWithString: "")
            let folder = (file.path as NSString).deletingLastPathComponent
            let text = NSMutableAttributedString(
                string: folder.isEmpty ? "" : folder + "/",
                attributes: [.font: NSFont.ui(TextSize.row), .foregroundColor: NSColor.secondaryLabelColor])
            text.append(
                NSAttributedString(
                    string: (file.path as NSString).lastPathComponent,
                    attributes: [.font: NSFont.ui(TextSize.row), .foregroundColor: NSColor.labelColor]))
            name.attributedStringValue = text
            name.lineBreakMode = .byTruncatingHead
            name.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            name.toolTip = file.path
            let line = NSStackView(views: [letter, name])
            line.spacing = 6
            line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
            return line
        }
        files.setViews(shown + more(list.count - shown.count), in: .top)
        files.isHidden = list.isEmpty
    }

    func showChanges() {
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
        showFiles(list)
        field.isHidden = changed == 0
        nothing.isHidden = changed > 0
        let typed = !message.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        hint.isHidden = changed == 0 || !hasRemote || !typed
        root.setCustomSpacing(hint.isHidden ? 12 : 6, after: field)
        let blocked = list.contains(where: \.conflicted) || GitSync.state(app).running[wid] != nil || committing
        commit.isEnabled = typed && !blocked
        commit.isBordered = commit.isEnabled
        message.isEnabled = !committing
    }
}
