import AppKit
import Core
import DesignKit
import WorkbenchKit

/// One row; `update()` re-reads the model, so status changes don't rebuild the outline.
@MainActor
final class SidebarCell: NSTableCellView {
    private let node: SidebarController.Node
    private weak var owner: SidebarController?
    let app: AppModel
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    /// Right side: how long ago the state changed ("4m"), or on a project what needs you.
    private let trailing = NSTextField(labelWithString: "")
    private let mark = StatusMark(size: 12)
    /// A chat's logo with its state in the corner, in the slot where the mark would be (Agent icons: Always): the name
    /// starts where the project's does, as it would with the mark alone.
    private let face = AgentFace()
    /// The mark, kept out of sight while the face says the state.
    private let markBox = NSView()
    /// The first thing in every row, in one column: at rest it says what the row is (an agent's mark, the column people
    /// scan for who needs them; a project's icon; a group's), under the pointer it's the row's own action (`action`), as a
    /// tab's slot is. Kept when empty, so names line up.
    private let slot = NSView()
    /// What the slot shows at rest.
    private weak var rest: NSView?
    /// A chat's ✕, a project's or a group's fold: 16 pt and round, as on a tab. Clicks reach it from a little around it.
    private lazy var action: PointerButton = {
        let button = PointerButton(title: "") { [weak self] in self?.acted() }
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.radius = nil   // a round fill under the pointer, the slot's 16 pt
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = .chrome(Metrics.iconTiny)
        button.isHidden = true
        return button
    }()
    /// Waits a moment after the pointer comes: passing over the list doesn't blink the marks people read.
    private let reveal = Debounce()
    /// An agent's own icon after its name, grey, when it isn't the default agent (Settings › Appearance › Agent icons).
    private let glyph = NSImageView()
    /// A project's colour after its name, in the Dot style.
    /// On the row that was muted (`Mutes`), not on what's inside it.
    private let muted: NSImageView = {
        let view = NSImageView(image: .symbol("bell.slash", String(localized: "Notifications muted")))
        view.symbolConfiguration = .chrome(Metrics.iconSmall)
        view.contentTintColor = .secondaryLabelColor
        view.toolTip = view.image?.accessibilityDescription
        view.isHidden = true
        return view
    }()
    /// Under an agent that asks or failed: what it asks, or what went wrong (Settings › Appearance › What agents ask).
    private let ask = NSTextField(labelWithString: "")
    private var rowY: NSLayoutConstraint?
    /// What an agent goes on with by itself: its /goal, or a command it started in the background.
    private let chip = Chip()
    /// An agent's: the agents it started.
    private lazy var family: ChildrenBadge = {
        let badge = ChildrenBadge()
        badge.opened = { [weak owner, node] in owner?.openCard(node) }
        return badge
    }()
    private var add: NSButton?
    /// A project's: the name of the one workspace it stands for (grey), what its agents do while it's folded, and the fold.
    /// A heading's: the branch its folder is on, when it has code of its own.
    private let detail = NSTextField(labelWithString: "")
    /// Folded, a project's or a group's chats, by their agents' logos (AgentStack).
    private let stack = AgentStack()
    /// What the chevron showed last: when that changes it turns rather than switches.
    private var shownFolded: Bool?
    private var hovering = false
    /// On the selection pill (SidebarRowView): grey text a step lighter there, where secondary label is 3.3:1.
    var selected = false { didSet { if selected != oldValue { update() } } }
    /// Grey text on the pill: 5.3:1 on dark's white 12%; light's white pill already gives secondary label 6:1.
    static let onPill = NSColor.dynamic(light: .secondaryLabelColor, dark: NSColor.white.withAlphaComponent(0.78))
    /// Changes not committed (a quiet dot, as on the title bar's branch: the counts are in its tooltip), the PR and its CI,
    /// for rows that stand for a folder (RowBadges); the dot goes first when the row is short of room, the CI mark last.
    private let changes = PointerButton(frame: .zero), pr = PointerButton(frame: .zero),
        ci = PointerButton(frame: .zero)
    private let ciMark = CIMark()

    init(node: SidebarController.Node, owner: SidebarController) {
        self.node = node
        self.owner = owner
        app = owner.app
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        trailing.font = .uiDigits(11, weight: .regular)
        trailing.textColor = .secondaryLabelColor
        // Not the cell's textField: the source list would restyle it, a project's as a grey group heading and a picked
        // row's in bold, which here means "something new". Type-select reads the name from the controller instead.
        textField = nil
        switch node.kind {
        case .project(let id):
            // A name, not a section label: what's under it is the project's. On the right only what needs doing.
            title.font = .ui(13, weight: .semibold)
            title.textColor = .labelColor
            trailing.font = .ui(11, weight: .semibold)
            trailing.textColor = .textOrange
            let button = Self.newChatButton { [weak owner] in owner?.newChat(id) }
            add = button   // on hover, like Finder's sidebar
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            fillSlot(icon)
            detail.font = .ui(12)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)   // goes before the project's name
            detail.setContentHuggingPriority(.init(1), for: .horizontal)   // takes the room, the badges sit at the right
            layout(row: [slot, title, muted, detail, stack, changes, pr, ci, trailing, button])
            detail.isHidden = true
        case .workspace:
            // A row like any other, with what's in it a step further in: a heading didn't say where it ended.
            title.font = .ui(13, weight: .medium)
            styleBranch()
            fillSlot(icon)
            layout(row: [slot, title, detail, muted, stack, changes, pr, ci, trailing])
        case .agent:
            title.font = .ui(13)
            glyph.imageScaling = .scaleProportionallyUpOrDown
            NSLayoutConstraint.activate([
                glyph.widthAnchor.constraint(equalToConstant: 12), glyph.heightAnchor.constraint(equalToConstant: 12)
            ])
            glyph.alphaValue = 0.75
            chip.isHidden = true
            fillSlot(lead())
            action.image = .symbol("xmark", String(localized: "Close Chat"))
            action.toolTip = String(localized: "Close Chat")
            layout(row: [slot, title, muted, glyph, chip, family, trailing])
            addAsk()
        case .host, .parked: break   // a ServerHeader, a ParkedHeader
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The name takes the room up to what's on the right: no spacer views, whose spacing on both sides read as a gap.
        title.setContentHuggingPriority(.init(2), for: .horizontal)
        // Grey in under the pointer and spring when clicked, as chips do. "+610 −23" and "#3" on a pill, as counts are
        // (Source Control's sections): bare, they read as part of the name.
        for badge in [changes, pr, ci] {
            badge.radius = badge === pr ? nil : Metrics.radiusXS
            badge.padding = badge === pr ? Metrics.gap : 3
            badge.restFill = badge === pr ? .fillRest : nil
            badge.target = self
        }
        changes.action = #selector(openChanges)
        pr.action = #selector(openPR)
        ci.action = #selector(openCI)
        ci.image = CIMark.room(12)
        ci.imagePosition = .imageOnly
        ci.addSubview(ciMark)
        NSLayoutConstraint.activate([
            ciMark.centerXAnchor.constraint(equalTo: ci.centerXAnchor),
            ciMark.centerYAnchor.constraint(equalTo: ci.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { showHoverControls(true) }
    override func mouseExited(with e: NSEvent) { showHoverControls(false) }

    /// The + comes in and the badges step aside (or out, where the name needs the room) in one movement: they jumped.
    /// The slot follows a moment later, and goes back at once. Reduce Motion: at once.
    private func showHoverControls(_ on: Bool) {
        hovering = on
        showChanges()
        ciMark.spelled = on
        if on {
            reveal.after(Motion.settle) { [weak self] in self?.showAction() }
        } else {
            reveal.cancel()
            showAction()
        }
        guard let add else { return }
        // What comes in fades in where it stands: moved with the rest, it flew in from where it last was, over the badges.
        let coming = on && add.isHidden
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.fast)
            ctx.allowsImplicitAnimation = true
            add.isHidden = !on
            fitBadges()
            layoutSubtreeIfNeeded()
            guard coming else { return }
            add.layer?.removeAllAnimations()
            guard !Motion.reduced else { return }
            let fade = CABasicAnimation(keyPath: "opacity")   // faint while the badges are still moving out of its way
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Motion.fast
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            add.layer?.add(fade, forKey: "fadeIn")
        }
    }

    /// The slot: `view` at rest, the row's action over it. Tracks the pointer for both.
    private func fillSlot(_ view: NSView) {
        rest = view
        slot.translatesAutoresizingMaskIntoConstraints = false
        for subview in [view, action] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                subview.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: 16), slot.heightAnchor.constraint(equalToConstant: 16),
            action.widthAnchor.constraint(equalToConstant: 16), action.heightAnchor.constraint(equalToConstant: 16)
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    private func acted() {
        if case .agent(let id) = node.kind { app.workbench.closeChat(session: id) } else { owner?.toggle(node) }
    }

    /// The action in the slot under the pointer: a row with nothing to fold keeps what it has.
    func showAction() {
        var on = hovering && owner?.renaming == nil
        if case .agent = node.kind {
        } else {
            on = on && !node.children.isEmpty
            showFold()
        }
        guard action.isHidden == on else { return }
        slot.crossfade()
        action.isHidden = !on
        // Faded, not hidden: whether it shows is its own (a read agent's mark hides itself), and unhiding brought back a ✓.
        rest?.alphaValue = on ? 0 : 1
    }

    /// The chevron turns as the row folds.
    private func showFold() {
        let folded = owner?.isCollapsed(node) ?? false
        action.image = .symbol(
            folded ? "chevron.right" : "chevron.down",
            folded ? String(localized: "Expand") : String(localized: "Collapse"))
        action.toolTip = action.image?.accessibilityDescription
        if let was = shownFolded, was != folded, !action.isHidden { action.turn(from: folded ? -.pi / 2 : .pi / 2) }
        shownFolded = folded
    }

    /// The pointer is on the slot's action: the row's card waits, the row's fate is being decided. `point` is in the window.
    func overAction(_ point: NSPoint) -> Bool { !action.isHidden && actionArea.contains(convert(point, from: nil)) }
    /// A little wider than what's drawn, from the pill's edge to the name, and as high as the pill.
    private var actionArea: NSRect { action.convert(action.bounds, to: self).insetBy(dx: -3, dy: -4) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !action.isHidden, actionArea.contains(convert(point, from: superview)) { return action }
        return super.hitTest(point)
    }

    private func layout(row: [NSView]) {
        let rowStack = NSStackView(views: row)
        rowStack.spacing = 6
        rowStack.alignment = .centerY
        rowStack.detachesHiddenViews = true
        for view in row where view === changes || view === pr || view === ci || view === stack {
            rowStack.setVisibilityPriority(.notVisible, for: view)
        }
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)
        // As tall as the + that comes in on hover: growing to it, the row's content rose and fell back.
        rowStack.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.iconButton).isActive = true
        let centerY = rowStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        rowY = centerY
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor), centerY
        ])
    }

    /// The folder this row stands for, if any (RowBadges.folder).
    private var folder: Worktree? {
        switch node.kind {
        case .project(let id): app.rowBadges.folder(project: id)
        case .workspace(let id): app.rowBadges.folder(workspace: id)
        case .agent, .host, .parked: nil
        }
    }
    @objc private func openChanges() {
        if let folder { app.workbench.open(TabURI.diff(folder.id), workspace: folder.id) }
    }
    @objc private func openPR() {
        if let folder, let url = app.rowBadges.prs[folder.id]?.url { app.workbench.open(url, workspace: folder.id) }
    }
    @objc private func openCI() { if let folder { app.rowBadges.openCI(folder.id) } }

    /// The stack shows a badge only when there's something to say, and drops it first when the row is narrow.
    private func updateBadges() {
        let badgeFolder = app.settings.bool("workbench.sidebar.gitBadges") == false ? nil : folder,
            stats = badgeFolder.flatMap { app.rowBadges.stats[$0.id] }
        let changeCounts = RowBadges.changes(stats)
        let prBadge = badgeFolder.flatMap { RowBadges.pr(app.rowBadges.prs[$0.id]) }
        counts = changeCounts
        showChanges()
        if changeCounts != nil, let stats {
            changes.toolTip = String(
                localized: "+\(stats.totalAdded) −\(stats.totalRemoved) not committed yet — click for the changes")
            changes.setAccessibilityLabel(changes.toolTip)
        }
        if let prBadge {
            pr.attributedTitle = prBadge.0
            pr.toolTip = prBadge.1
        }
        let state = folder.flatMap { app.rowBadges.sidebarCI($0.id) }
        ciMark.state = state
        ci.toolTip = folder.flatMap { app.rowBadges.ciLine($0.id) }.map {
            $0 + "\n" + String(localized: "Click to open CI Runs")
        }
        ci.setAccessibilityLabel(ci.toolTip)
        hasBadge = (changeCounts != nil, prBadge != nil, state != nil)
        fitBadges()
    }
    private var hasBadge = (changes: false, pr: false, ci: false)
    /// "+610 −23", shown in place of the dot while the pointer is on the row.
    private var counts: NSAttributedString?
    /// A quiet dot at rest; under the pointer the counts, on a pill as the PR's number is (bare they read as the name's).
    private func showChanges() {
        let full = hovering ? counts : nil, title = full ?? Self.dot
        if changes.attributedTitle != title { changes.attributedTitle = title }
        changes.padding = full == nil ? 3 : Metrics.gap
        changes.restFill = full == nil ? nil : .fillRest
    }
    private static var dot: NSAttributedString {
        NSAttributedString(
            string: "•",
            attributes: [.font: NSFont.ui(12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
    }

    /// Badges show while the name fits beside them: they step aside before it truncates (left to itself the stack
    /// squeezes the name instead: "kdrde…  +2 −1").
    private func fitBadges() {
        guard let rowStack = changes.superview as? NSStackView else { return }
        let others = rowStack.views.filter { $0 !== changes && $0 !== pr && $0 !== ci && $0 !== stack && !$0.isHidden }
        var room = bounds.width - 2 - others.reduce(0) { $0 + max(0, $1.intrinsicContentSize.width) + rowStack.spacing }
        for (badge, has) in [(ci, hasBadge.ci), (changes, hasBadge.changes), (pr, hasBadge.pr)] {
            let need = badge.intrinsicContentSize.width + (badge === ci ? ciMark.overhang : 0) + rowStack.spacing,
                show = has && room >= need
            if show { room -= need }
            rowStack.setVisibilityPriority(show ? .mustHold : .notVisible, for: badge)
        }
        // The agents' logos take what's left: fewer of them, then none ("+N" counts the rest; the tooltip names all).
        let fits = (0...stack.count).last { stack.width(showing: $0) + rowStack.spacing <= room } ?? 0
        stack.cap = fits
        rowStack.setVisibilityPriority(fits > 0 ? .mustHold : .notVisible, for: stack)
    }
    override func setFrameSize(_ size: NSSize) {
        let old = frame.width
        super.setFrameSize(size)
        if size.width != old { fitBadges() }
    }

    func update() {
        defer { trailing.isHidden = trailing.stringValue.isEmpty }   // an empty label would still take its spacing
        muted.isHidden = app.mutedUntil(node.muteIds) == nil
        updateBadges()
        func live(_ wid: String) -> [Session] {
            app.sessions.filter { $0.worktreeId == wid && $0.status != .exited && $0.isChat }
        }
        switch node.kind {
        case .project(let id):
            let repo = app.repo(id)
            let missing = repo.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
            if let repo, !missing {
                ProjectIcon.show(repo.path, in: icon, app: app)
            } else {
                icon.image = missing ? .symbol("questionmark.folder") : nil
            }
            icon.contentTintColor = .secondaryLabelColor
            // Not under a rename (a status change re-reads the row). A remote one's server heads its card, not its name.
            if !title.isEditable {
                title.stringValue = owner?.projectHosts[id] == nil ? app.projectName(id) ?? "" : repo?.name ?? ""
            }
            // Stronger where agents are: a project with none is a quieter name the eye passes over. Bold is left to news.
            let busy =
                !missing && node.children.contains { if case .agent = $0.kind { true } else { !$0.children.isEmpty } }
            title.font = .ui(13, weight: busy ? .medium : .regular)
            // Over workspace headings it stays the parent: primary, never greyer than the rows under it.
            title.textColor = busy || selected || !node.children.isEmpty ? .labelColor : .secondaryLabelColor
            toolTip =
                missing
                ? String(localized: "\(repo?.path ?? "") isn't there anymore. Right-click › Locate… if it moved.")
                : repo.map(app.projectPlace)
            // Who needs you is on the agents' own rows and in the line above the projects; folded, the row sums them up.
            trailing.stringValue = missing ? String(localized: "Folder missing") : ""
            if !detail.isEditable {
                detail.stringValue = ""
                detail.isHidden = true
            }
            let folded = owner?.isCollapsed(node) == true
            if let was = shownFolded, was != folded { stack.crossfade(Motion.base) }   // folding, not a status change
            stack.show(folded ? AgentStack.chats(under: node, app) : [], app)
            fitBadges()
            showFold()
        case .workspace(let id):
            guard let worktree = app.worktree(id) else { return }
            let agents = live(id)
            title.stringValue = worktree.displayName
            title.textColor = .labelColor
            // A branch splits the code, a group the screen: the slot tells them apart, always.
            let onBranch = worktree.path != app.repo(worktree.repoId)?.path
            icon.image = .symbol(onBranch ? "arrow.triangle.branch" : "rectangle.stack")
            detail.stringValue = onBranch && worktree.branch != worktree.displayName ? worktree.branch : ""
            detail.isHidden = detail.stringValue.isEmpty
            showFold()
            // Expanded, its agents show their own state; collapsed, the workspace sums them up.
            let collapsed = owner?.isCollapsed(node) ?? false
            let top = AgentStatus.mostUrgent(agents.map(Self.shownStatus))
            let lead = agents.filter { Self.shownStatus($0) == top }.max {
                ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt)
            }
            trailing.stringValue =
                collapsed ? shortAgo(lead.map { $0.statusAt ?? $0.createdAt }) : "\(node.children.count)"
            stack.show(collapsed ? AgentStack.chats(under: node, app) : [], app)
            fitBadges()
            toolTip = nil   // the hover card shows the workspace in full
        case .agent(let sid):
            guard let session = app.session(sid) else { return }
            showIcon(session)
            title.stringValue = app.catalog.displayName(session)
            title.font = .ui(13, weight: Self.isNews(session) ? .semibold : .regular)
            mark.status = Self.shownStatus(session)
            mark.unread = session.unread
            mark.limited = session.limitHit != nil
            mark.compacting = session.summary.hasPrefix("Compacting")
            mark.waitsForCommand = session.waitsForCommand
            mark.guessed = session.guessed == true
            mark.progress = session.progress.map { Double($0) / 100 }
            showFace(session)
            // How long it has waited for you is worth the room; how long the rest has been at it isn't, the name is.
            // A chat with no project working in a folder you picked says which (its own folders are just dates).
            let repo = app.worktree(session.worktreeId).flatMap { app.repo($0.repoId) }
            let picked =
                NoProject.holds(repo) && (session.cwd as NSString).deletingLastPathComponent != repo?.path
                ? (session.cwd as NSString).lastPathComponent : ""
            // Working with no news for minutes says so where the time goes: a ring alone would say it's busy (`quietSince`).
            let quiet =
                Self.shownStatus(session) == .working
                ? session.quietSince.map { String(localized: "quiet \(shortAgo($0))") } : nil
            trailing.stringValue =
                [.waiting, .error].contains(Self.shownStatus(session))
                ? shortAgo(session.statusAt ?? session.createdAt)
                : app.arrangement.parked[sid].flatMap { app.isParked(sid) ? Parking.until($0) : nil } ?? quiet ?? picked
            alphaValue = app.isParked(sid) ? 0.55 : 1   // out of the way, as the canvas draws it
            family.show(
                app.sessions.children(of: sid), running: session.runningSubagents, finished: session.finishedSubagents)
            showChip(session)
            showState(session)
            showAsk(session)
            speak(session)
        case .host, .parked: break
        }
    }

    /// The agent's icon: before its name when Agent icons is Always, a grey glyph after it for an agent other than the
    /// default one (Other Agents Only), none for Never. In colour while the agent is loaded; paused, the same icon without
    /// its colour (not see-through: a faded tile read wider than the others), so what's unloaded reads at a glance.
    private func showIcon(_ session: Session) {
        let mode = app.settings.string("workbench.sidebar.agentIcons") ?? "others",
            image = app.catalog.icon(session.agent, size: 16)
        face.isHidden = mode != "always"
        markBox.isHidden = !face.isHidden
        face.image = session.status == .paused ? image.map(app.agentIcons.grey) : image
        face.alphaValue = session.status == .paused ? 0.7 : 1
        glyph.isHidden = mode != "others" || session.agent == app.catalog.defaultAgent
        let mark = glyph.isHidden ? nil : image.map(app.agentIcons.grey)
        if glyph.image !== mark { glyph.image = mark }
        glyph.toolTip = app.catalog.name(session.agent)
        glyph.setAccessibilityLabel(glyph.toolTip)
    }

    /// The slot's two looks, one shown (`showIcon`): the mark, or the logo with the mark in its corner.
    private func lead() -> NSView {
        let view = NSView()
        markBox.addSubview(mark)
        for (child, side) in [(markBox, 16.0), (face, AgentFace.side)] as [(NSView, CGFloat)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.widthAnchor.constraint(equalToConstant: side),
                child.heightAnchor.constraint(equalToConstant: side),
                child.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                child.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: markBox.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: markBox.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: 16), view.heightAnchor.constraint(equalToConstant: 16)
        ])
        return view
    }

    /// The face's corner says what the row's mark would.
    private func showFace(_ session: Session) {
        let faceMark = face.mark
        faceMark.status = mark.status
        faceMark.unread = mark.unread
        faceMark.limited = mark.limited
        faceMark.compacting = mark.compacting
        faceMark.waitsForCommand = mark.waitsForCommand
        faceMark.guessed = mark.guessed
        faceMark.progress = mark.progress
        face.cut()
    }

    /// VoiceOver reads the row as one sentence: "Fix login, needs your input, Asks: may I run npm test?, Atlas, now",
    /// not its mark, name, line and time one by one.
    private func speak(_ session: Session) {
        let st = Self.shownStatus(session), project = app.projectName(app.worktree(session.worktreeId)?.repoId)
        let state = mark.isHidden ? nil : st.words
        let line = ask.isHidden ? nil : ask.stringValue, quiet = muted.isHidden ? nil : muted.toolTip
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            [title.stringValue, state, line, quiet, project, trailing.stringValue].compactMap { $0 }.filter {
                !$0.isEmpty
            }
            .joined(separator: ", "))
        mark.announces = false
        for part in [title, ask, trailing] as [NSView] { part.setAccessibilityElement(false) }
    }

    /// One line, as Mail lists mailboxes: an agent asking for you or done unseen is bold (isNews) and its mark says which;
    /// the colour stays on the mark (orange text on a light sidebar is 2:1). What it asks or did is on the hover card.
    private func showState(_ session: Session) {
        title.textColor = session.status == .paused ? .secondaryLabelColor : .labelColor
        trailing.textColor = selected ? Self.onPill : .secondaryLabelColor
        toolTip = nil
    }

    /// A mark for the goal it works toward, else for what runs beside it, as on its tab, else for the machine it runs a
    /// command in (`kelp vm run`). Words have no room here: a name and a chip shared the same points, and a command mostly
    /// ended before it could be read. The tooltip and the card say them.
    private func showChip(_ session: Session) {
        let beside = session.aside.count,
            mark = beside == 0 ? app.extensions.all.sessionMarks.lazy.compactMap({ $0(session) }).first : nil
        // Beside the dots there's no room for both it and the name: the card lists what it says.
        chip.isHidden = !family.isHidden || (session.goal == nil && beside == 0 && mark == nil)
        if let goal = session.goal {
            chip.show("scope")
            chip.toolTip = String(localized: "Goal: \(goal)")
        } else {
            chip.show(mark?.symbol ?? "apple.terminal", count: beside)
            chip.toolTip = mark?.tip ?? session.backgroundTip
        }
        chip.setAccessibilityLabel(chip.toolTip)
    }

    /// The workspace's name: its own row's title, or the grey name beside its project's; with `project` the project's own
    /// name, without the machine its row may add.
    func beginEditing(delegate: NSTextFieldDelegate, project: Bool = false) {
        if project, case .project(let id) = node.kind { title.stringValue = app.repo(id)?.name ?? "" }
        title.isEditable = true
        title.isSelectable = true
        title.drawsBackground = true
        title.delegate = delegate
        window?.makeFirstResponder(title)
        title.currentEditor()?.selectAll(nil)
    }
}

extension SidebarCell {
    /// A project's "+", hidden until the pointer is on the row. Small and faint there, brighter on the button itself: at
    /// 13 pt secondary it was the biggest mark in the row.
    fileprivate static func newChatButton(_ action: @escaping () -> Void) -> IconButton {
        let button = IconButton(.symbol("plus"), tip: String(localized: "New Chat"), action: action)
        button.isHidden = true
        button.symbolConfiguration = .chrome(Metrics.iconSmall)
        button.tints = (.tertiaryLabelColor, .secondaryLabelColor)
        // Its square, whatever the row's stack had left when it appeared on hover (it came out narrower than tall).
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.iconButton),
            button.heightAnchor.constraint(equalToConstant: Metrics.iconButton)
        ])
        return button
    }

    /// A group's row: its branch quieter than its name, and what gives way first.
    fileprivate func styleBranch() {
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .chrome()
        detail.font = .ui(11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)
    }
}

/// The second line: what an agent asks, or what went wrong.
extension SidebarCell {
    /// The second line, under the name: what an agent asks.
    private func addAsk() {
        ask.font = .ui(11)
        ask.lineBreakMode = .byTruncatingTail
        ask.usesSingleLineMode = true
        ask.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ask.isHidden = true
        ask.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ask)
        NSLayoutConstraint.activate([
            ask.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            ask.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            ask.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        ])
    }

    /// The second line, and the name moved up to make room for it; the outline gives the row the height (`hasAsk`).
    private func showAsk(_ session: Session) {
        let line = Self.line(
            session, mode: app.settings.string("workbench.sidebar.agentDetail") ?? "needsYou", among: app.sessions,
            back: app.arrangement.parkedBack[session.id])
        setAsk(line)
    }

    /// Shows `line` under the name, the name moved up to make room for it; nil: one line.
    private func setAsk(_ line: (prefix: (String, NSColor)?, text: String)?) {
        ask.isHidden = line == nil
        rowY?.constant = line == nil ? 0 : -TextSize.of(8)
        guard let line else { return }
        let grey = selected ? Self.onPill : NSColor.secondaryLabelColor, font = NSFont.ui(11)
        let styled = NSMutableAttributedString()
        // On the pill too: the text shades hold 4.5:1 on it (light 5.5, dark 4.9), and the row it marks is the one you're on.
        if let (word, color) = line.prefix {
            styled.append(NSAttributedString(string: word + " ", attributes: [.font: font, .foregroundColor: color]))
        }
        styled.append(NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: grey]))
        // Its own: an attributed string without one is cut off at the edge, not ended with "…" (the field's mode isn't used).
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        styled.addAttribute(.paragraphStyle, value: tail, range: NSRange(location: 0, length: styled.length))
        ask.attributedStringValue = styled
        ask.toolTip = line.text
    }
}
