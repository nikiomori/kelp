import AppKit
import Core
import DesignKit
import WorkbenchKit

/// One row; `update()` re-reads the model, so status changes don't rebuild the outline.
@MainActor
final class SidebarCell: NSTableCellView {
    let node: SidebarController.Node
    weak var owner: SidebarController?
    let app: AppModel
    let icon = NSImageView()
    /// Behind the slot: the project's colour, lit while the pointer is over its group (Icon style, `glowIcon`).
    private let glow = CALayer()
    private var glowColor: ProjectColor?
    func glowIcon(_ on: Bool) {
        guard let glowColor else { return }
        ProjectIcon.glow(glow, color: glowColor, on)
    }
    let title = NSTextField(labelWithString: "")
    /// Right side: how long ago the state changed ("4m"), or on a project what needs you.
    let trailing = NSTextField(labelWithString: "")
    let mark = StatusMark(size: 12)
    /// A chat's logo with its state in the corner, in the slot where the mark would be (Agent icons: Always): the name
    /// starts where the project's does, as it would with the mark alone.
    let face = AgentFace()
    /// The mark, kept out of sight while the face says the state.
    let markBox = NSView()
    /// The first thing in every row, in one column: at rest it says what the row is (an agent's mark, the column people
    /// scan for who needs them; a project's icon; a group's), under the pointer it's the row's own action (`action`), as a
    /// tab's slot is. Kept when empty, so names line up.
    let slot = NSView()
    /// What the slot shows at rest.
    weak var rest: NSView?
    /// A chat's ✕, a project's or a group's fold: 16 pt and round, as on a tab. Clicks reach it from a little around it.
    lazy var action: PointerButton = {
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
    let reveal = Debounce()
    /// An agent's own icon after its name, grey, when it isn't the default agent (Settings › Appearance › Agent icons).
    let glyph = NSImageView()
    /// A project's colour after its name, in the Dot style.
    /// On the row that was muted (`Mutes`), not on what's inside it.
    let muted: NSImageView = {
        let view = NSImageView(image: .symbol("bell.slash", String(localized: "Notifications muted")))
        view.symbolConfiguration = .chrome(Metrics.iconSmall)
        view.contentTintColor = .secondaryLabelColor
        view.toolTip = view.image?.accessibilityDescription
        view.isHidden = true
        return view
    }()
    /// Under an agent that asks or failed: what it asks, or what went wrong (Settings › Appearance › What agents ask).
    let ask = NSTextField(labelWithString: "")
    var rowY: NSLayoutConstraint?
    /// What an agent goes on with by itself: its /goal, or a command it started in the background.
    let chip = Chip()
    /// An agent's: the agents it started.
    lazy var family: ChildrenBadge = {
        let badge = ChildrenBadge()
        badge.onClick = { [weak owner, node] in owner?.openCard(node) }
        return badge
    }()
    var add: NSButton?
    /// A group on a branch that holds nothing of its own and has nobody on it: it can simply go (`showGroupLine`).
    lazy var remove: TextButton = {
        let button = TextButton(String(localized: "Remove")) { [weak self] in
            guard let self, case .workspace(let id) = node.kind, let worktree = app.worktree(id) else { return }
            WorkspaceActions(app).close(worktree)
        }
        button.toolTip = String(localized: "Everything on this branch is on another branch or a remote too")
        button.isHidden = true
        return button
    }()
    /// A project's: the name of the one workspace it stands for (grey), what its agents do while it's folded, and the fold.
    /// A heading's: the branch its folder is on, when it has code of its own.
    let detail = NSTextField(labelWithString: "")
    /// Folded, a project's or a group's chats, by their agents' logos (AgentStack).
    let stack = AgentStack()
    /// What the chevron showed last: when that changes it turns rather than switches.
    var shownFolded: Bool?
    var hovering = false
    /// On the selection pill (SidebarRowView): grey text a step lighter there, where secondary label is 3.3:1.
    var selected = false { didSet { if selected != oldValue { update() } } }
    /// Grey text on the pill: 5.3:1 on dark's white 12%; light's white pill already gives secondary label 6:1.
    static let onPill = NSColor.dynamic(light: .secondaryLabelColor, dark: NSColor.white.withAlphaComponent(0.78))
    /// Changes not committed (a quiet dot, as on the title bar's branch: the counts are in its tooltip), the PR and its CI,
    /// for rows that stand for a folder (GitFolders; the CI from FolderCI); the dot goes first when the row is short of
    /// room, the CI mark last.
    let changes = PointerButton(frame: .zero), pr = PointerButton(frame: .zero),
        ci = PointerButton(frame: .zero)
    let ciMark = CIMark()
    var hasBadge = (changes: false, pr: false, ci: false)
    /// "+610 −23", shown in place of the dot while the pointer is on the row.
    var counts: NSAttributedString?
    /// Another folder of the project changes some of these files too: the dot is orange (`GitFolders.shared`).
    var shares = false

    init(node: SidebarController.Node, owner: SidebarController) {
        self.node = node
        self.owner = owner
        app = owner.app
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        trailing.font = .uiDigits(TextSize.caption, weight: .regular)
        trailing.textColor = .secondaryLabelColor
        // Not the cell's textField: the source list would restyle it, a project's as a grey group heading and a picked
        // row's in bold, which here means "something new". Type-select reads the name from the controller instead.
        textField = nil
        switch node.kind {
        case .project(let id):
            // A name, not a section label: what's under it is the project's. On the right only what needs doing.
            title.font = .ui(TextSize.body, weight: .semibold)
            title.textColor = .labelColor
            trailing.font = .ui(TextSize.caption, weight: .semibold)
            trailing.textColor = .textOrange
            let button = Self.newChatButton { [weak owner] in owner?.newChat(id) }
            add = button   // on hover, like Finder's sidebar
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            fillSlot(icon)
            slot.wantsLayer = true
            glow.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            slot.layer?.insertSublayer(glow, at: 0)
            detail.font = .ui(TextSize.row)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)   // goes before the project's name
            detail.setContentHuggingPriority(.init(1), for: .horizontal)   // takes the room, the badges sit at the right
            layout(row: [slot, title, muted, detail, stack, changes, pr, ci, trailing, button])
            detail.isHidden = true
        case .workspace:
            // A row like any other, with what's in it a step further in: a heading didn't say where it ended.
            title.font = .ui(TextSize.body, weight: .medium)
            styleBranch()
            fillSlot(icon)
            layout(row: [slot, title, detail, muted, stack, changes, pr, ci, remove, trailing])
        case .agent:
            title.font = .ui(TextSize.body)
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
        case .host, .parked: break   // a server's header (ServerCards), a ParkedHeader
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

    override func setFrameSize(_ size: NSSize) {
        let old = frame.width
        super.setFrameSize(size)
        if size.width != old { fitBadges() }
    }

    func update() {
        defer { trailing.isHidden = trailing.stringValue.isEmpty }   // an empty label would still take its spacing
        muted.isHidden = app.arrangement.mutedUntil(node.muteIds) == nil
        updateBadges()
        switch node.kind {
        case .project(let id):
            let repo = app.repo(id)
            let missing = repo.map { app.missingFolders.contains($0.path) } ?? false
            glowColor = repo.flatMap { app.arrangement.iconColor(folder: $0.path) }
            if glowColor == nil { glow.shadowOpacity = 0 }
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
            title.font = .ui(TextSize.body, weight: busy ? .medium : .regular)
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
            title.stringValue = worktree.displayName
            title.textColor = .labelColor
            // A branch splits the code, a group the screen: the slot tells them apart, always.
            let onBranch = worktree.path != app.repo(worktree.repoId)?.path
            icon.image = .symbol(onBranch ? "arrow.triangle.branch" : "rectangle.stack")
            showGroupLine(worktree, onBranch: onBranch)
            showFold()
            // Expanded, its agents show their own state; collapsed, the workspace sums them up.
            let collapsed = owner?.isCollapsed(node) ?? false
            let lead = app.lead(in: id)
            trailing.stringValue =
                collapsed
                ? shortAgo(lead.map { $0.statusAt ?? $0.createdAt })
                : node.children.isEmpty ? "" : "\(node.children.count)"
            stack.show(collapsed ? AgentStack.chats(under: node, app) : [], app)
            fitBadges()
            toolTip = nil   // the hover card shows the workspace in full
        case .agent(let sid):
            guard let session = app.session(sid) else { return }
            showIcon(session)
            title.stringValue = app.catalog.displayName(session)
            title.font = .ui(TextSize.body, weight: Self.isNews(session) ? .semibold : .regular)
            mark.status = Self.shownStatus(session)
            mark.unread = session.unread
            mark.limited = session.limitHit != nil
            mark.compacting = session.compacting
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
                : app.arrangement.parked[sid].flatMap { app.arrangement.isParked(sid) ? Parking.until($0) : nil }
                    ?? quiet ?? picked
            alphaValue = app.arrangement.isParked(sid) ? 0.55 : 1   // out of the way, as the canvas draws it
            family.show(
                app.children(of: sid), running: session.runningSubagents, finished: session.finishedSubagents)
            showChip(session)
            showState(session)
            showAsk(session)
            speak(session)
        case .host, .parked: break
        }
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
        detail.font = .ui(TextSize.caption)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)
    }
}

/// The second line: what an agent asks, or what went wrong.
extension SidebarCell {
    /// The second line, under the name: what an agent asks.
    private func addAsk() {
        ask.font = .ui(TextSize.caption)
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
            session, mode: app.settings[SettingKeys.agentDetail], children: app.children(of: session.id),
            back: app.arrangement.parkedBack[session.id], plans: app.extensions.all.plans)
        setAsk(line)
    }

    /// Shows `line` under the name, the name moved up to make room for it; nil: one line.
    private func setAsk(_ line: (prefix: (String, NSColor)?, text: String)?) {
        ask.isHidden = line == nil
        rowY?.constant = line == nil ? 0 : -TextSize.of(8)
        guard let line else { return }
        let grey = selected ? Self.onPill : NSColor.secondaryLabelColor, font = NSFont.ui(TextSize.caption)
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
