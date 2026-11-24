import AppKit
import Core
import DesignKit
import WorkbenchKit

/// One row of the sidebar. `update()` re-reads the model, so a status change doesn't rebuild the outline.
@MainActor
final class SidebarCell: NSTableCellView {
    let node: SidebarController.Node
    weak var owner: SidebarController?
    let app: AppModel
    let icon = NSImageView()
    /// A layer behind the slot in the project's colour. It lights up while the pointer is over the project's group
    /// (in the Icon style, see `glowIcon`).
    private let glow = CALayer()
    private var glowColor: ProjectColor?
    func glowIcon(_ on: Bool) {
        guard let glowColor else { return }
        ProjectIcon.glow(glow, color: glowColor, on)
    }
    let title = RowLabel(labelWithString: "")
    /// The label on the right. It shows how long ago the state changed ("4m"), or, on a project's row, what needs you.
    let trailing = RowLabel(labelWithString: "")
    let mark = StatusMark(size: 12)
    /// The logo of the chat's agent, with the chat's state in its corner. It sits in the slot where the status mark
    /// would be (when Agent icons is set to Always), so the name starts where the project's name does, just as it
    /// would with the mark alone.
    let face = AgentFace()
    /// Holds the status mark. It is hidden while the face shows the state.
    let markBox = NSView()
    /// The first thing in every row, all in one column. At rest it says what the row is: an agent's mark (the column
    /// people scan to see who needs them), a project's icon, or a group's. Under the pointer it becomes the row's own
    /// action (`action`), like the slot on a tab. It is kept even when empty, so the names line up.
    let slot = NSView()
    /// What the slot shows at rest.
    weak var rest: NSView?
    /// The small button on a row: a chat's ✕, or the fold of a project or a group. It is 16 pt and round, as on a tab,
    /// and clicks a little outside it still reach it.
    lazy var action = PointerButton.slot { [weak self] in self?.acted() }
    /// Waits a moment after the pointer arrives, so moving across the list doesn't make the marks people read blink.
    let reveal = Debounce()
    /// The agent's own icon in grey after the name. It shows when the agent isn't the default one (Settings ›
    /// Appearance › Agent icons).
    let glyph = NSImageView()
    /// A crossed-out bell after the name of a muted row. It goes on the row that was muted (`Mutes`), not on the rows
    /// inside it. A click unmutes the row, as the hover card's Unmute does.
    lazy var muted: PointerButton = {
        let button = PointerButton(image: .symbol("bell.slash", String(localized: "Notifications muted"))) {
            [weak self] in
            guard let self else { return }
            app.arrangement.mute(node.muteIds, until: nil)
        }
        button.radius = nil
        button.symbolConfiguration = .chrome(Metrics.iconSmall)
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(String(localized: "Unmute"))
        button.isHidden = true
        return button
    }()
    /// Shown on a project whose folder is gone: "Folder missing" in orange, because it waits for you, on the grey plate
    /// of a worded button, because words without one don't read as a button. A click asks where the folder went.
    lazy var locate: PointerButton = {
        let button = PointerButton { [weak self] in
            guard let self, case .project(let id) = node.kind, let repo = app.repo(id) else { return }
            WorkspaceActions(app).relocate(repo)
        }
        button.attributedTitle = NSAttributedString(
            string: String(localized: "Folder missing"),
            attributes: [.font: NSFont.ui(TextSize.caption), .foregroundColor: NSColor.textOrange])
        button.radius = Metrics.radiusXS
        button.padding = Metrics.gap
        button.restFill = .fillRest
        button.toolTip = String(localized: "Locate…")
        button.isHidden = true
        return button
    }()
    /// The line under an agent that asks or failed. It shows the question or what went wrong (Settings › Appearance ›
    /// What agents ask).
    let ask = NSTextField(labelWithString: "")
    var rowY: NSLayoutConstraint?
    /// What the second line last showed (`setAsk`).
    var askShown: [String] = []
    /// What the agent works on by itself: its /goal, or a command it started in the background.
    let chip = Chip()
    /// On an agent's row, a badge for the agents it started.
    lazy var family: ChildrenBadge = {
        let badge = ChildrenBadge()
        badge.onClick = { [weak owner, node] in owner?.openCard(node) }
        return badge
    }()
    /// On an agent's row, a button mark that a built-in adds (for example, for the page the agent drives).
    /// `buttonMark` is the mark it shows (`showMarkButton`).
    lazy var markButton = Self.markButton(self)
    var buttonMark: RowMark?
    var add: NSButton?
    /// The Remove button on a group whose branch holds nothing of its own and has no agents on it, so the group can
    /// simply go (`showGroupLine`).
    lazy var remove: TextButton = {
        let button = TextButton(String(localized: "Remove")) { [weak self] in
            guard let self, case .workspace(let id) = node.kind, let worktree = app.worktree(id) else { return }
            WorkspaceActions(app).close(worktree)
        }
        button.toolTip = String(localized: "Everything on this branch is on another branch or a remote too")
        button.isHidden = true
        return button
    }()
    /// On a project's row, this shows in grey the name of the one workspace the row stands for, what the project's
    /// agents do while it is folded, and the fold button.
    /// On a heading's row, it shows the branch of the heading's folder, when that folder has code of its own.
    let detail = NSTextField(labelWithString: "")
    /// The chats of a folded project or group, shown as their agents' logos (AgentStack).
    let stack = AgentStack()
    /// On an empty group's row, the hourglass that counts down the last of its time (`showCountdown`).
    let hourglass = NSImageView()
    /// The hourglass symbol on show, so the sand runs out once, when it changes.
    var sand: String?
    /// Whether the chevron last showed the row folded. When this changes, the chevron turns instead of switching.
    var shownFolded: Bool?
    var hovering = false
    /// True when the row is on the selection pill (SidebarRowView). Grey text is a step lighter there, because the
    /// secondary label colour gives only 3.3:1 on the pill.
    var selected = false { didSet { if selected != oldValue { update() } } }
    /// The grey for text on the pill. In dark mode, 78 % white on the 12 % white pill gives 5.3:1. In light mode, the
    /// white pill already gives the secondary label 6:1.
    static let onPill = NSColor.dynamic(light: .secondaryLabelColor, dark: NSColor.white.withAlphaComponent(0.78))
    /// Badges on rows that stand for a folder: uncommitted changes, the PR, and the PR's CI. The changes badge is a
    /// quiet dot, as on the title bar's branch, with the counts in its tooltip (from GitFolders; the CI is from
    /// FolderCI). When the row is short of room, the dot goes first and the CI mark goes last.
    let changes = PointerButton(frame: .zero), pr = PointerButton(frame: .zero),
        ci = PointerButton(frame: .zero)
    let ciMark: CIMarkSlot
    var hasBadge = (changes: false, pr: false, ci: false)
    /// "+610 −23", shown in place of the dot while the pointer is on it.
    var counts: NSAttributedString?
    /// The git mark under the pointer, which spells out its meaning in words while hovered (`spell`).
    weak var spelling: NSView?
    /// True when another folder of the project changes some of the same files. The dot is then doubled
    /// (`GitFolders.shared`).
    var shares = false

    init(node: SidebarController.Node, owner: SidebarController) {
        self.node = node
        self.owner = owner
        app = owner.app
        ciMark = CIMarkSlot(owner.app)
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        trailing.font = .uiDigits(TextSize.caption, weight: .regular)
        trailing.textColor = .secondaryLabelColor
        trailing.lineBreakMode = .byTruncatingTail
        // Not the cell's textField: the source list would restyle it, drawing a project's name as a grey group heading
        // and a selected row's name in bold, which here means "something new". Type-select reads the name from the
        // controller instead.
        textField = nil
        switch node.kind {
        case .project(let id):
            // Styled as the project's name, not as a section label, because what is under it belongs to the project.
            // The right side shows only what needs doing. Regular weight, as every name in this column: semibold
            // here means news.
            title.font = .ui(TextSize.body)
            title.textColor = .labelColor
            let button = Self.newChatButton { [weak owner] in owner?.newChat(id) }
            add = button   // shown on hover, like Finder's sidebar
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            fillSlot(icon)
            slot.wantsLayer = true
            glow.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            slot.layer?.insertSublayer(glow, at: 0)
            detail.font = .ui(TextSize.caption)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)
            layout(row: [slot, title, detail, muted, stack, changes, pr, ci, locate, button])
        case .workspace:
            // A group is a row like any other, with its contents a step further in, because a heading didn't show
            // where the group ended.
            title.font = .ui(TextSize.body)
            styleBranch()
            fillSlot(icon)
            hourglass.symbolConfiguration = .chrome(Metrics.iconSmall)
            hourglass.contentTintColor = .secondaryLabelColor
            hourglass.isHidden = true
            layout(row: [slot, title, detail, muted, stack, changes, pr, ci, remove, hourglass, trailing])
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
            // A chat on its own branch shows that branch's marks, as a screen on a branch does.
            layout(row: [slot, title, muted, glyph, chip, family, markButton, stack, changes, pr, ci, trailing])
            addAsk()
        case .host, .parked: break   // these are a server's header (ServerCards) and a ParkedHeader
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The name takes the room up to what's on the right. There are no spacer views, because their spacing on both
        // sides read as a gap.
        title.setContentHuggingPriority(.init(2), for: .horizontal)
        // The badges fill grey under the pointer and spring when clicked, as chips do. "+610 −23" and "#3" sit on a
        // pill, as counts do in Source Control's sections, because bare they read as part of the name.
        for badge in [changes, pr, ci] {
            badge.radius = badge === pr ? nil : Metrics.radiusXS
            badge.padding = badge === pr ? Metrics.gap : Metrics.iconGap
            badge.restFill = badge === pr ? .fillRest : nil
            badge.target = self
        }
        stack.onMore = { [weak owner, node] in owner?.toggle(node) }
        for badge in [changes, ci] { badge.onHover = { [weak self, weak badge] in self?.spell(badge, $0) } }
        changes.action = #selector(openChanges)
        pr.action = #selector(openPR)
        ci.action = #selector(openCI)
        ci.image = CIMarkSlot.room(12)
        ci.imagePosition = .imageOnly
        ci.addSubview(ciMark.view)
        NSLayoutConstraint.activate([
            ciMark.view.centerXAnchor.constraint(equalTo: ci.centerXAnchor),
            ciMark.view.centerYAnchor.constraint(equalTo: ci.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { showHoverControls(true) }
    override func mouseExited(with event: NSEvent) { showHoverControls(false) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !action.isHidden, actionArea.contains(convert(point, from: superview)) { return action }
        return super.hitTest(point)
    }

    private func layout(row: [NSView]) {
        let rowStack = NSStackView(views: row)
        rowStack.spacing = Metrics.gap
        rowStack.alignment = .centerY
        rowStack.detachesHiddenViews = true
        for view in row where view === changes || view === pr || view === ci || view === stack {
            rowStack.setVisibilityPriority(.notVisible, for: view)
        }
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)
        // The row is as tall as the + that appears on hover. When the row grew to fit the +, its content rose and
        // fell back.
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
        let mutedUntil = app.arrangement.mutedUntil(node.muteIds)
        muted.isHidden = mutedUntil == nil
        muted.toolTip = mutedUntil.map(Mutes.line)
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
            // Leave the name alone during a rename, because a status change re-reads the row. A remote project's
            // server heads its card, so the name leaves the server out.
            if !title.isEditable {
                title.stringValue = owner?.projectHosts[id] == nil ? app.projectName(id) ?? "" : repo?.name ?? ""
            }
            // A project with no agents is a quieter, grey name the eye passes over. Its weight doesn't change:
            // semibold is kept for news.
            let busy =
                !missing
                && (!node.hidden.isEmpty
                    || node.children.contains {
                        if case .agent = $0.kind { true } else { !$0.children.isEmpty || !$0.hidden.isEmpty }
                    })
            // Above workspace headings the project is their parent, so its name stays primary, never greyer than the
            // rows under it.
            title.textColor = busy || selected || node.holds ? .labelColor : .secondaryLabelColor
            toolTip =
                missing
                ? String(localized: "\(repo?.path ?? "") isn’t there anymore. Right-click › Locate… if it moved.")
                : repo.map(app.projectPlace)
            say([title.stringValue, toolTip])
            // The agents' own rows and the line above the projects show who needs you. When the project is folded,
            // its row sums them up.
            locate.isHidden = !missing
            // Its folder's branch, in grey, while that isn't the project's base: an agent may have checked another out
            // in the project's own folder. With a row for the project's own screen, that row says it.
            let current = folder.flatMap { app.gitState.branch($0.id) }
            detail.stringValue = current.flatMap { $0 == repo?.baseBranch ? nil : $0 } ?? ""
            detail.isHidden = detail.stringValue.isEmpty
            let folded = owner?.isCollapsed(node) == true
            if let was = shownFolded, was != folded { stack.crossfade(Motion.base) }   // on a fold, not a status change
            // Folded, a project with one screen holds its chats as logos; one with more leaves them to its screens.
            stack.show(folded ? node.hidden.compactMap(app.session) : [], app)
            fitBadges()
            showFold()
        case .workspace(let id):
            guard let worktree = app.worktree(id) else { return }
            // The project's own screen, which has a row once the project has others, is named by its folder's branch,
            // as the window bar names it.
            let own = isOwnScreen
            title.stringValue =
                own && (worktree.note.isEmpty || worktree.isUnnamed)
                ? app.gitState.branch(id) ?? worktree.branch : worktree.displayName
            title.textColor = .labelColor
            // A branch splits the code and a group splits the screen, so the icon in the slot always tells them apart.
            let onBranch = worktree.path != app.repo(worktree.repoId)?.path
            icon.image = .symbol(onBranch ? "arrow.triangle.branch" : own ? "macwindow" : "rectangle.stack")
            showGroupLine(worktree, onBranch: onBranch)
            showFold()
            // When the workspace is expanded, its agents show their own state. When collapsed, its row sums them up.
            let collapsed = owner?.isCollapsed(node) ?? false
            let lead = app.lead(in: id)
            trailing.stringValue =
                collapsed
                ? shortAgo(lead.map { $0.statusAt ?? $0.createdAt })
                : node.children.isEmpty ? "" : "\(node.children.count)"
            // In a folded project, the screen's row holds its chats as logos.
            let held = node.hidden.compactMap(app.session)
            stack.show(!held.isEmpty ? held : collapsed ? AgentStack.chats(under: node, app) : [], app)
            showCountdown(worktree)
            fitBadges()
            toolTip = nil   // the hover card shows the workspace in full
            speakGroup(onBranch: onBranch)
        case .agent(let sid):
            guard let session = app.session(sid) else { return }
            showIcon(session)
            title.stringValue = app.catalog.displayName(session)
            title.font = .ui(TextSize.body, weight: session.isNews ? .semibold : .regular)
            mark.status = session.shownStatus
            mark.unread = session.unread
            mark.follow(session)
            showFace(session)
            // How long an agent has waited for you is worth the room. How long the others have been working isn't, so
            // the name gets the room. A chat with no project that works in a folder you picked shows that folder's
            // name (the chat's own folders are only dates).
            let repo = app.worktree(session.worktreeId).flatMap { app.repo($0.repoId) }
            let picked =
                NoProject.holds(repo) && (session.cwd as NSString).deletingLastPathComponent != repo?.path
                ? (session.cwd as NSString).lastPathComponent : ""
            // An agent working with no news for minutes says "quiet" where the time goes, because the ring alone would
            // say it is busy (`quietSince`).
            let quiet =
                session.shownStatus == .working
                ? session.quietSince.map { String(localized: "quiet \(shortAgo($0))") } : nil
            let waited = [.waiting, .error].contains(session.shownStatus)
            trailing.stringValue =
                waited
                ? shortAgo(session.statusAt ?? session.createdAt)
                : app.arrangement.parked[sid].flatMap { app.arrangement.isParked(sid) ? Parking.until($0) : nil }
                    ?? quiet ?? picked
            // On a narrow sidebar the waited time keeps its room; the rest gives way to the name first.
            trailing.setContentCompressionResistancePriority(waited ? .defaultHigh : .init(240), for: .horizontal)
            alphaValue = app.arrangement.isParked(sid) ? 0.55 : 1   // a parked chat is dimmed, as the canvas draws it
            showMarkButton(sid)
            family.show(
                app.children(of: sid), running: session.runningSubagents, finished: session.finishedSubagents)
            showChip(session)
            showState(session)
            showAsk(session)
            speak(session)
        case .host, .parked: break
        }
    }

    /// True on the row of a project's own screen (once the project has other screens).
    var isOwnScreen: Bool {
        guard case .workspace(let id) = node.kind else { return false }
        return (owner?.outline.parent(forItem: node) as? SidebarController.Node)?.workspace == id
    }

    /// Starts editing the workspace's name: the title of its own row, or the grey name beside the project's name. With
    /// `project`, it edits the project's own name, without the machine name the project's row may add.
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
    /// Makes a project's "+", hidden until the pointer is on the row. It is small and faint on the row and brighter
    /// under the pointer, because at 13 pt in secondary grey it was the biggest mark in the row.
    fileprivate static func newChatButton(_ action: @escaping () -> Void) -> IconButton {
        let button = IconButton(.symbol("plus"), tip: String(localized: "New Chat"), action: action)
        button.isHidden = true
        button.symbolConfiguration = .chrome(Metrics.iconSmall)
        button.tints = (.tertiaryLabelColor, .secondaryLabelColor)
        // A fixed square, whatever room the row's stack had left when the button appeared on hover (without this it
        // came out narrower than tall).
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.iconButton),
            button.heightAnchor.constraint(equalToConstant: Metrics.iconButton)
        ])
        return button
    }

    /// Styles a group's row: the branch is quieter than the name, and this sets what gives way first.
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
    /// Adds the second line under the name, for what an agent asks.
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

    /// Shows the second line and moves the name up to make room for it. The outline gives the row its height
    /// (`hasAsk`).
    private func showAsk(_ session: Session) {
        let line = session.rowLine(
            mode: app.settings[SettingKeys.agentDetail], children: app.children(of: session.id),
            back: app.arrangement.parkedBack[session.id], plans: app.extensions.all.plans)
        setAsk(line)
    }

    /// Shows `line` under the name and moves the name up to make room for it. A nil line leaves one line.
    private func setAsk(_ line: (prefix: (String, NSColor)?, text: String)?) {
        let coming = ask.isHidden && line != nil, flips = ask.isHidden != (line == nil)
        ask.isHidden = line == nil
        // The name moves up as the row opens (in the row's animation group, see `sessionsChanged`), and the line comes
        // a beat after. A reused cell that is being filled shows at once.
        let y = line == nil ? 0 : -TextSize.of(8)
        if flips, window != nil { rowY?.animator().constant = y } else { rowY?.constant = y }
        if coming, window != nil, !Motion.reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.beginTime = CACurrentMediaTime() + Motion.stagger
            fade.fillMode = .backwards
            fade.duration = Motion.fast
            ask.wantsLayer = true
            ask.layer?.add(fade, forKey: "opacity")
        }
        guard let line else { return }
        // When the line and the pill are as before (most news doesn't change them), skip styling and measuring again.
        let key = [line.prefix?.0, line.prefix?.1.description, line.text, "\(selected)"].map { $0 ?? "" }
        guard key != askShown else { return }
        askShown = key
        let grey = selected ? Self.onPill : NSColor.secondaryLabelColor, font = NSFont.ui(TextSize.caption)
        let styled = NSMutableAttributedString()
        // The prefix keeps its colour on the pill too, because the text shades hold 4.5:1 there (light 5.5, dark 4.9)
        // and the row it marks is the one you're on.
        if let (word, color) = line.prefix {
            styled.append(NSAttributedString(string: word + " ", attributes: [.font: font, .foregroundColor: color]))
        }
        styled.append(NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: grey]))
        // The string needs its own paragraph style, because without one it is cut off at the edge instead of ending in
        // "…" (the field's line break mode isn't used).
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        styled.addAttribute(.paragraphStyle, value: tail, range: NSRange(location: 0, length: styled.length))
        ask.attributedStringValue = styled
        ask.toolTip = line.text
    }
}

/// A row's label that does nothing when it is set to the text it already shows. A field that is set again measures
/// itself and lays out its row anew, and rows are set again on every agent's news.
final class RowLabel: NSTextField {
    override var stringValue: String {
        get { super.stringValue }
        set { if newValue != super.stringValue { super.stringValue = newValue } }
    }
    override var font: NSFont? {
        get { super.font }
        set { if newValue != super.font { super.font = newValue } }
    }
    override var textColor: NSColor? {
        get { super.textColor }
        set { if newValue != super.textColor { super.textColor = newValue } }
    }
}
