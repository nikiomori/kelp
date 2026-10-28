import AppKit
import Core
import DesignKit
import WorkbenchKit

/// One row; `update()` re-reads the model, so status changes don't rebuild the outline.
@MainActor
final class SidebarCell: NSTableCellView {
    private let node: SidebarController.Node
    private weak var owner: SidebarController?
    private let app: AppModel
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    /// Right side: how long ago the state changed ("4m"), or on a project what needs you.
    private let trailing = NSTextField(labelWithString: "")
    private let mark = StatusMark(size: 12)
    /// An agent's mark, first in its row: the column people scan for who needs them. Kept when empty, so names line up.
    private let slot = NSView()
    /// An agent's own icon after its name, grey, when it isn't the default agent (Settings › Appearance › Agent icons).
    private let glyph = NSImageView()
    /// Under an agent that asks or failed: what it asks, or what went wrong (Settings › Appearance › What agents ask).
    private let ask = NSTextField(labelWithString: "")
    private var rowY: NSLayoutConstraint?
    /// What an agent goes on with by itself: its /goal, or a command it started in the background.
    private let chip = Chip()
    private var add: NSButton?
    /// A project's: the name of the one workspace it stands for (grey), what its agents do while it's folded, and the fold.
    private let detail = NSTextField(labelWithString: "")
    private let summary = NSStackView()
    private var fold: NSButton?
    private var hovering = false
    /// On the selection pill (SidebarRowView): grey text a step lighter there, where secondary label is 3.3:1.
    var selected = false { didSet { if selected != oldValue { update() } } }
    /// Grey text on the pill: 5.3:1 on dark's white 12%; light's white pill already gives secondary label 6:1.
    static let onPill = NSColor.dynamic(light: .secondaryLabelColor, dark: NSColor.white.withAlphaComponent(0.78))
    /// Lines not committed and the PR, for rows that stand for a folder (RowBadges); they go first when the row is short of room.
    private let changes = NSButton(), pr = NSButton()

    init(node: SidebarController.Node, owner: SidebarController) {
        self.node = node
        self.owner = owner
        app = owner.app
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        trailing.font = .uiDigits(11, weight: .regular); trailing.textColor = .secondaryLabelColor
        // Not the cell's textField: the source list would restyle it, a project's as a grey group heading and a picked
        // row's in bold, which here means "something new". Type-select reads the name from the controller instead.
        textField = nil
        switch node.kind {
        case .project(let id):
            // A name, not a section label: what's under it is the project's. On the right only what needs doing.
            title.font = .ui(13, weight: .semibold)
            title.textColor = .labelColor
            trailing.font = .ui(11, weight: .semibold); trailing.textColor = .textOrange
            let b = IconButton(.symbol("plus"), tip: String(localized: "New workspace (⌘N)")) { [weak owner] in owner?.newWorkspace(id) }
            b.isHidden = true
            add = b   // on hover, like Finder's sidebar
            let f = makeFold()
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true; icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            detail.font = .ui(12)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)   // goes before the project's name
            summary.spacing = 3
            detail.setContentHuggingPriority(.init(1), for: .horizontal)   // takes the room, the badges sit at the right
            layout(row: [icon, title, detail, summary, changes, pr, trailing, b, f])
            detail.isHidden = true   // the workspace's name shows in the hover card; here only while it's renamed
        case .section:
            title.font = .ui(11, weight: .semibold); title.textColor = .secondaryLabelColor
            count.font = .uiDigits(11, weight: .medium); count.textColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            layout(row: [icon, title, count, NSView()])
        case .workspace:
            // A heading over its agents inside the project's card, not a level of its own: the sidebar stays two deep.
            title.font = .ui(11, weight: .semibold)
            title.textColor = .secondaryLabelColor
            layout(row: [title, changes, pr, trailing, mark, makeFold()])
        case .agent:
            title.font = .ui(13)
            for (v, side) in [(icon, 14.0), (glyph, 12.0)] {
                v.imageScaling = .scaleProportionallyUpOrDown
                NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: side), v.heightAnchor.constraint(equalToConstant: side)])
            }
            glyph.alphaValue = 0.75
            ask.font = .ui(11.5)
            ask.lineBreakMode = .byTruncatingTail
            ask.usesSingleLineMode = true
            ask.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            ask.isHidden = true
            chip.isHidden = true
            // The name keeps its room first; the chip shortens its command down to its icon and an ellipsis, never less,
            // and a long command takes no more than a third of the row.
            chip.setContentCompressionResistancePriority(.init(200), for: .horizontal)
            let least = chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 40); least.priority = .init(760)
            NSLayoutConstraint.activate([least, chip.widthAnchor.constraint(lessThanOrEqualToConstant: 72)])
            slot.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(mark)
            NSLayoutConstraint.activate([slot.widthAnchor.constraint(equalToConstant: 12), slot.heightAnchor.constraint(equalToConstant: 12),
                                         mark.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                                         mark.centerYAnchor.constraint(equalTo: slot.centerYAnchor)])
            layout(row: [slot, icon, title, glyph, chip, trailing])
            (title.superview as? NSStackView)?.setCustomSpacing(8, after: slot)
            ask.translatesAutoresizingMaskIntoConstraints = false; addSubview(ask)
            NSLayoutConstraint.activate([ask.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                                         ask.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                                         ask.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)])
        }
        for v in [title, count] { v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        // The name takes the room up to what's on the right: no spacer views, whose spacing on both sides read as a gap.
        if case .section = node.kind {} else { title.setContentHuggingPriority(.init(2), for: .horizontal) }
        for b in [changes, pr] {
            b.isBordered = false
            b.title = ""
            b.target = self
        }
        changes.action = #selector(openChanges); pr.action = #selector(openPR)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) {
        hovering = true
        add?.isHidden = false
        showFold()
        fitBadges()
    }
    override func mouseExited(with e: NSEvent) {
        hovering = false
        add?.isHidden = true
        showFold()
        fitBadges()
    }

    /// The chevron that folds a project or a workspace, at the row's end; shown by `showFold`.
    private func makeFold() -> NSButton {
        let f = ClosureButton(title: "") { [weak owner, node] in owner?.toggle(node) }
        f.isBordered = false
        f.contentTintColor = .secondaryLabelColor
        f.isHidden = true
        f.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        fold = f
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        return f
    }

    /// The fold shows on hover, like Finder's sections, and stays while folded: the row says there's more under it.
    private func showFold() {
        guard let fold else { return }
        let folded = owner?.isCollapsed(node) ?? false
        fold.isHidden = node.children.isEmpty || !(hovering || folded)
        fold.image = .symbol(folded ? "chevron.right" : "chevron.down", folded ? String(localized: "Expand") : String(localized: "Collapse"))
    }

    private func layout(row: [NSView]) {
        let r = NSStackView(views: row)
        r.spacing = 6
        r.alignment = .centerY
        r.detachesHiddenViews = true
        for v in row where v === changes || v === pr { r.setVisibilityPriority(.notVisible, for: v) }
        r.translatesAutoresizingMaskIntoConstraints = false; addSubview(r)
        let y = r.centerYAnchor.constraint(equalTo: centerYAnchor)
        rowY = y
        NSLayoutConstraint.activate([r.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), r.trailingAnchor.constraint(equalTo: trailingAnchor), y])
    }

    /// The folder this row stands for, if any (RowBadges.folder).
    private var folder: Worktree? {
        switch node.kind {
        case .project(let id): app.rowBadges.folder(project: id)
        case .workspace(let id): app.rowBadges.folder(workspace: id)
        case .agent, .section: nil
        }
    }
    @objc private func openChanges() { if let w = folder { app.workbench.open(TabURI.diff(w.id), workspace: w.id) } }
    @objc private func openPR() { if let w = folder, let u = app.rowBadges.prs[w.id]?.url { app.workbench.open(u, workspace: w.id) } }

    /// The stack shows a badge only when there's something to say, and drops it first when the row is narrow.
    private func updateBadges() {
        let w = app.settings.bool("workbench.sidebar.gitBadges") == false ? nil : folder, stats = w.flatMap { app.rowBadges.stats[$0.id] }
        let c = RowBadges.changes(stats, compact: true)
        let p = w.flatMap { RowBadges.pr(app.rowBadges.prs[$0.id]) }
        if let c, let stats {
            changes.attributedTitle = c
            changes.toolTip = String(localized: "+\(stats.totalAdded) −\(stats.totalRemoved) not committed yet — click for the changes")
        }
        if let p { pr.attributedTitle = p.0; pr.toolTip = p.1 }
        hasBadge = (c != nil, p != nil)
        fitBadges()
    }
    private var hasBadge = (changes: false, pr: false)

    /// Badges show while the name fits beside them: they step aside before it truncates (left to itself the stack
    /// squeezes the name instead: "kdrde…  +2 −1").
    private func fitBadges() {
        guard let r = changes.superview as? NSStackView else { return }
        let others = r.views.filter { $0 !== changes && $0 !== pr && !$0.isHidden }
        var room = bounds.width - 2 - others.reduce(0) { $0 + max(0, $1.intrinsicContentSize.width) + r.spacing }
        for (b, has) in [(changes, hasBadge.changes), (pr, hasBadge.pr)] {
            let need = b.intrinsicContentSize.width + r.spacing, show = has && room >= need
            if show { room -= need }
            r.setVisibilityPriority(show ? .mustHold : .notVisible, for: b)
        }
    }
    override func setFrameSize(_ s: NSSize) {
        let old = frame.width
        super.setFrameSize(s)
        if s.width != old { fitBadges() }
    }

    func update() {
        defer { trailing.isHidden = trailing.stringValue.isEmpty }   // an empty label would still take its spacing
        updateBadges()
        let m = app
        func live(_ wid: String) -> [Session] { m.sessions.filter { $0.worktreeId == wid && $0.status != .exited && $0.agent != "shell" } }
        switch node.kind {
        case .project(let id):
            let r = m.repo(id)
            let missing = r.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
            if let r, !missing { ProjectIcon.show(r.path, in: icon, app: m) } else { icon.image = missing ? .symbol("questionmark.folder") : nil }
            icon.contentTintColor = .secondaryLabelColor
            if !title.isEditable { title.stringValue = m.projectName(id) ?? "" }   // not under a rename (a status change re-reads the row)
            // Bold where agents are: a project with none is a quieter name the eye passes over.
            let busy = !missing && node.children.contains { if case .agent = $0.kind { true } else { !$0.children.isEmpty } }
            title.font = .ui(13, weight: busy ? .semibold : .regular)
            title.textColor = busy || selected ? .labelColor : .secondaryLabelColor
            toolTip = missing ? String(localized: "\(r?.path ?? "") isn't there anymore. Right-click › Locate… if it moved.") : r.map(m.projectPlace)
            // Who needs you is on the agents' own rows and in the line above the projects; folded, the row sums them up.
            trailing.stringValue = missing ? String(localized: "Folder missing") : ""
            if !detail.isEditable { detail.isHidden = true }
            showSummary(owner?.isCollapsed(node) == true ? node : nil)
            showFold()
        case .section:
            icon.image = .symbol("pin.fill"); icon.contentTintColor = .secondaryLabelColor
            title.stringValue = String(localized: "Pinned")
            count.stringValue = "\(node.children.count)"; toolTip = nil
        case .workspace(let id):
            guard let w = m.worktree(id) else { return }
            let agents = live(id)
            title.stringValue = w.displayName
            title.textColor = selected ? .labelColor : .secondaryLabelColor
            showFold()
            // Expanded, its agents show their own state; collapsed, the workspace sums them up.
            let collapsed = owner?.isCollapsed(node) ?? false
            let top = AgentStatus.mostUrgent(agents.map(Self.shownStatus))
            let lead = agents.filter { Self.shownStatus($0) == top }.max { ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt) }
            mark.status = collapsed ? top : nil; mark.unread = agents.contains { Self.shownStatus($0) == top && $0.unread }
            trailing.stringValue = collapsed ? shortAgo(lead.map { $0.statusAt ?? $0.createdAt }) : ""
            toolTip = nil   // the hover card shows the workspace in full
        case .agent(let sid):
            guard let s = m.session(sid) else { return }
            showIcon(s)
            title.stringValue = app.catalog.displayName(s)
            title.font = .ui(13, weight: Self.isNews(s) ? .semibold : .regular)
            mark.status = Self.shownStatus(s)
            mark.unread = s.unread
            mark.compacting = s.summary.hasPrefix("Compacting")
            mark.progress = s.progress.map { Double($0) / 100 }
            trailing.stringValue = s.status == .idle ? "" : shortAgo(s.statusAt ?? s.createdAt)
            showChip(s)
            showState(s)
            showAsk(s)
            speak(s)
        }
    }

    /// The agent's icon: before its name when Agent icons is Always, a grey glyph after it for an agent other than the
    /// default one (Other Agents Only), none for Never.
    private func showIcon(_ s: Session) {
        let mode = app.settings.string("workbench.sidebar.agentIcons") ?? "always", image = app.catalog.icon(s.agent, size: 16)
        icon.isHidden = mode != "always"
        // Paused: the same icon without its colour, not see-through (a faded tile read wider than the others).
        icon.image = s.status == .hibernated ? image?.grayscale : image
        icon.alphaValue = s.status == .hibernated ? 0.7 : 1
        glyph.isHidden = mode != "others" || s.agent == app.catalog.defaultAgent
        glyph.image = image?.grayscale
        glyph.toolTip = app.catalog.name(s.agent)
        glyph.setAccessibilityLabel(glyph.toolTip)
    }

    /// The second line, and the name moved up to make room for it; the outline gives the row the height (`hasAsk`).
    private func showAsk(_ s: Session) {
        let line = Self.askLine(s, mode: app.settings.string("workbench.sidebar.agentDetail") ?? "needsYou")
        ask.isHidden = line == nil
        rowY?.constant = line == nil ? 0 : -TextSize.of(8)
        guard let line else { return }
        let grey = selected ? Self.onPill : NSColor.secondaryLabelColor, font = NSFont.ui(11)
        let t = NSMutableAttributedString()
        if let (word, color) = line.prefix {   // on the pill the word goes grey too: orange there is 3:1, the mark keeps the colour
            t.append(NSAttributedString(string: word + " ", attributes: [.font: font, .foregroundColor: selected ? grey : color]))
        }
        t.append(NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: grey]))
        ask.attributedStringValue = t
        ask.toolTip = line.text
    }

    /// VoiceOver reads the row as one sentence: "Fix login, needs your input, Asks: may I run npm test?, Atlas, now",
    /// not its mark, name, line and time one by one.
    private func speak(_ s: Session) {
        let st = Self.shownStatus(s), project = app.projectName(app.worktree(s.worktreeId)?.repoId)
        let state = mark.isHidden ? nil : st.words
        let line = ask.isHidden ? nil : ask.stringValue
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([title.stringValue, state, line, project, trailing.stringValue].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", "))
        mark.announces = false
        for v in [title, ask, trailing] as [NSView] { v.setAccessibilityElement(false) }
    }

    /// "Asks: may I run npm test?", "Failed: rate limit until 14:00": what an agent that needs you wants, in its own
    /// words (its summary); with `always` every agent says what it's on. Nil: no second line.
    static func askLine(_ s: Session, mode: String) -> (prefix: (String, NSColor)?, text: String)? {
        let st = shownStatus(s), text = s.summary.isEmpty ? st.words : s.summary
        switch (mode, st) {
        case ("never", _): return nil
        case (_, .waiting): return ((String(localized: "Asks:"), .textOrange), text)
        case (_, .error): return ((String(localized: "Failed:"), .textRed), text)
        case ("always", _): return (nil, text)
        default: return nil
        }
    }

    /// A folded project's agents, by what they want: asking (or failed), working, done and not looked at.
    private func showSummary(_ folded: SidebarController.Node?) {
        summary.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let ids = folded.map { n in n.children.flatMap { $0.children.isEmpty ? [$0] : $0.children } } ?? []
        let agents = ids.compactMap { n -> Session? in if case .agent(let id) = n.kind { app.session(id) } else { nil } }
        let shown = agents.map(Self.shownStatus)
        let asking = shown.filter { [.waiting, .error].contains($0) }
        let groups: [(AgentStatus?, Int)] = [(AgentStatus.mostUrgent(asking), asking.count), (.working, shown.filter { $0 == .working }.count),
                                             (.done, agents.filter { Self.isNews($0) && Self.shownStatus($0) == .done }.count)]
        var tip: [String] = []
        for case let (status?, n) in groups where n > 0 {
            let mark = StatusMark(size: 12)
            mark.status = status
            mark.unread = true
            let count = NSTextField(labelWithString: "\(n)")
            count.font = .uiDigits(11, weight: .medium)
            count.textColor = .secondaryLabelColor
            summary.addArrangedSubview(mark); summary.addArrangedSubview(count)
            summary.setCustomSpacing(6, after: count)
            tip.append("\(n) · \(status.words)")
        }
        summary.isHidden = tip.isEmpty
        summary.toolTip = tip.joined(separator: ", "); summary.setAccessibilityLabel(summary.toolTip)
    }

    /// One line, as Mail lists mailboxes: an agent asking for you or done unseen is bold (isNews) and its mark says which;
    /// the colour stays on the mark (orange text on a light sidebar is 2:1). What it asks or did is on the hover card.
    private func showState(_ s: Session) {
        title.textColor = s.status == .hibernated ? .secondaryLabelColor : .labelColor
        trailing.textColor = selected ? Self.onPill : .secondaryLabelColor
        toolTip = nil
    }

    /// "◎ goal" while it works toward one; "▷ npm test" while it waits for a command it started; "▷ 2" for what keeps
    /// running in the background after its turn (a dev server). The full text is the tooltip.
    private func showChip(_ s: Session) {
        let running = s.background ?? []
        chip.isHidden = s.goal == nil && running.isEmpty
        if let g = s.goal {
            chip.icon.image = .symbol("scope")
            chip.label.stringValue = String(localized: "goal")
            chip.toolTip = String(localized: "Goal: \(g)")
        } else if !running.isEmpty {
            let waits = s.status == .working, first = running[0]
            chip.icon.image = .symbol("apple.terminal")
            chip.label.stringValue = waits ? first : "\(running.count)"
            chip.toolTip = (waits ? String(localized: "Waits for its command:") : String(localized: "Running in the background:"))
                + "\n" + running.joined(separator: "\n")
        }
        chip.setAccessibilityLabel(chip.toolTip)
    }

    /// Asks for you, failed, or finished and not looked at yet.
    static func wantsYou(_ s: Session) -> Bool {
        let st = shownStatus(s)
        return s.agent != "shell" && (st == .waiting || st == .error || (st == .done && s.unread))
    }

    /// A paused agent's row is dimmed, but what it finished and you haven't read keeps its bright mark.
    static func shownStatus(_ s: Session) -> AgentStatus { s.status == .hibernated && s.unread ? .done : s.markStatus }

    /// Something to look at: finished or asking, and not opened since (bold, like unread mail).
    static func isNews(_ s: Session) -> Bool { s.unread && [.done, .waiting, .error].contains(shownStatus(s)) }

    /// The workspace's name: its own row's title, or the grey name beside its project's; with `project` the project's own
    /// name, without the machine its row may add.
    func beginEditing(delegate: NSTextFieldDelegate, project: Bool = false) {
        let field = node.workspace == nil || project ? title : detail
        if project, case .project(let id) = node.kind {
            title.stringValue = app.repo(id)?.name ?? ""
        } else if let w = node.workspace.flatMap(app.worktree) { detail.stringValue = w.displayName; detail.isHidden = false }
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.delegate = delegate
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
}

/// What an agent goes on with by itself, beside its name: a symbol and a word on a faint capsule. A label, not a button:
/// a squeezed inline-bezel button wrapped its title ("p/" over "cl") taller than the row; a label shortens with "…".
@MainActor
final class Chip: NSView {
    let icon = NSImageView(), label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        label.font = .ui(10)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let s = NSStackView(views: [icon, label])
        s.spacing = 3
        s.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     s.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: TextSize.of(16))])
        setContentCompressionResistancePriority(.init(200), for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)   // read by its label (SidebarCell.showChip): the whole command
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {   // the appearance is current here: the fill follows light and dark
        layer?.cornerRadius = Metrics.radiusXS
        layer?.backgroundColor = NSColor.fillRest.cgColor
    }
}
