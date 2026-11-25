import AppKit
import Core
import DesignKit

/// The window's first row, the title bar. It shows where you are (the workspace, its folder with Open In, Finder and
/// Copy Path, its branch and its pull request), with Open Quickly (⌘P) in the middle and Back / Forward beside it. The
/// window controller puts the panel toggles in the corners and lines the workspace up with the editor area. The tab
/// strips of the panes are the second row.
@MainActor
final class WindowBar: NSView {
    /// The height of the system title bar (28 pt before macOS 26, 32 after). The traffic lights sit on its centre line.
    static let height = Metrics.titleBar
    /// The widest the branch's chip gets: about twenty-four letters with its glyph and counts.
    private static let branchMost: CGFloat = 180

    /// The icon, name, folder, branch and pull request. It is hidden when there is no workspace.
    let context = NSStackView()
    private let icon = NSImageView(), name = NSTextField(labelWithString: "")
    private let folder = WindowBar.chip(nil), branch = WindowBar.chip("arrow.triangle.branch"),
        pr = WindowBar.chip("arrow.triangle.pull")
    private let search: SearchPill
    /// The tools to the right of the search: the run parts (`ProjectRuns.bar`), the cup, and side by side.
    private let tools = NSStackView()
    private var runParts: [any WindowBarItem] = []
    let app: AppModel
    let back = NSButton.titlebar("chevron.left", String(localized: "Back"), tip: "")
    let forward = NSButton.titlebar("chevron.right", String(localized: "Forward"), tip: "")
    let awake = NSButton.titlebar("cup.and.saucer", String(localized: "Keep Mac Awake"), tip: "")
    let sideBySide = NSButton.titlebar("rectangle.split.3x1", String(localized: "Agents Side by Side"), tip: "")
    /// The branch chip's data: the on-screen workspace's git state, as the daemon pushes it (ChangedFiles watches it).
    private var info: BranchInfo? { event?.shownBranches }
    private var event: GitEvent? { app.latest(GitEvent.self, app.gitKey(app.workbench.mainWorkspaceId)) }

    /// Whether the workspace on screen has uncommitted changes (a dot on the chip). `syncing` is what a sync running
    /// there says.
    private var dirty: Bool {
        !(app.latest(GitEvent.self, app.gitKey(app.workbench.mainWorkspaceId))?.changes ?? []).isEmpty
    }
    private var syncing: String? { app.workbench.mainWorkspaceId.flatMap { app.extensions.all.branch?.running($0) } }
    /// Why the background fetch fails, and its mark once it has failed for long (`BranchActions.fetch`).
    private var fetchTrouble: (said: String, mark: String?)? {
        app.workbench.mainWorkspaceId.flatMap { app.extensions.all.branch?.fetch($0) }
    }
    private let popover = NSPopover()
    private var closedAt = Date.distantPast

    /// The workspace on screen. It is nil over a page, because the project and branch would be those of the workspace
    /// behind the page.
    var worktree: Worktree? { app.workbench.page == nil ? app.worktree(app.workbench.mainWorkspaceId) : nil }
    /// The folder the sidebar keeps the pull request and CI for. A workspace shares its project's folder.
    private var badgeFolder: Worktree? { app.gitFolder(of: app.workbench.mainWorkspaceId) }
    /// The branch's CI (Settings › Appearance › CI) goes in place of the chip's glyph, after the counts, or nowhere.
    private let ciMark: CIMarkSlot
    /// The CI mark is centred on the glyph's slot (the chip's padding, then 13 pt), or on the room left at the end of
    /// the title (12 pt).
    private lazy var ciAtStart = ciMark.view.centerXAnchor.constraint(
        equalTo: branch.leadingAnchor, constant: Self.chipPadding + 13 / 2)
    private lazy var ciAtEnd = ciMark.view.centerXAnchor.constraint(
        equalTo: branch.trailingAnchor, constant: -(Self.chipPadding + 12 / 2))
    static let chipPadding: CGFloat = 6
    /// The CI mark and its place, from the CI built-in (`FolderCI`). Without that built-in the chip shows no CI.
    private var ci: (state: CIRuns.State, atEnd: Bool)? { badgeFolder.flatMap { app.extensions.all.ci?.chip($0.id) } }
    /// The branch's pull request, from the CI built-in (`FolderCI`). Without that built-in there is no PR chip.
    var prMark: (title: NSAttributedString, tip: String, uri: String, page: URL?)? {
        badgeFolder.flatMap { app.extensions.all.ci?.pr($0.id) }
    }
    /// "CI: Failed · Tests" for the tooltip and VoiceOver, whatever the chip shows.
    private var ciLine: String? { badgeFolder.flatMap { app.extensions.all.ci?.line($0.id) } }

    init(app: AppModel) {
        self.app = app
        ciMark = CIMarkSlot(app)
        search = SearchPill(app: app)
        super.init(frame: .zero)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(450), for: .horizontal)
        folder.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        // A branch's name has no end to its length: past this the chip cuts it in the middle, so the search stays in
        // the centre of a window of ordinary width.
        branch.widthAnchor.constraint(lessThanOrEqualToConstant: Self.branchMost).isActive = true
        folder.target = self
        folder.action = #selector(folderMenu)
        folder.toolTip = String(localized: "Open In, Reveal in Finder, Copy Path")
        branch.target = self
        branch.action = #selector(branchClicked)
        branch.addSubview(ciMark.view)
        ciMark.view.centerYAnchor.constraint(equalTo: branch.centerYAnchor).isActive = true
        pr.target = self
        pr.action = #selector(openPR)
        for chip in [branch, back, forward] {
            chip.menu = NSMenu()
            chip.menu?.delegate = self
        }
        context.setViews([icon, name, folder, branch, pr], in: .leading)
        context.spacing = Metrics.iconGap
        context.setCustomSpacing(Metrics.gap, after: icon)
        context.setCustomSpacing(Metrics.gap, after: name)
        context.setCustomSpacing(Metrics.gapWide, after: folder)
        awake.target = self
        awake.action = #selector(toggleAwake)
        sideBySide.target = self
        sideBySide.action = #selector(toggleSideBySide)
        let hide = NSMenu()
        Self.addHide(to: hide, SettingKeys.sideBySideButton, app)
        sideBySide.menu = hide
        back.target = self
        back.action = #selector(goBack)
        forward.target = self
        forward.action = #selector(goForward)
        let nav = NSStackView(views: [back, forward])
        nav.spacing = 0
        // To the right of the search go what runs here (gone while the project offers nothing), the page it serves, the
        // cup, and side by side (with two agents or more).
        for button in [awake, sideBySide] { tools.addArrangedSubview(button) }
        tools.spacing = 2
        tools.detachesHiddenViews = true
        for part in [context, nav, search, tools] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        // When room is short, the search leaves the centre first, then narrows. Only then does the path shorten, and
        // then the name. All of these sit below the window's own size (500), so a long path or name truncates instead
        // of widening the window.
        let wide = search.widthAnchor.constraint(equalToConstant: 280)
        wide.priority = .init(250)
        let center = search.centerXAnchor.constraint(equalTo: centerXAnchor)
        center.priority = .init(200)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            context.centerYAnchor.constraint(equalTo: centerYAnchor),
            search.centerYAnchor.constraint(equalTo: centerYAnchor),
            wide, center,
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            search.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            back.widthAnchor.constraint(equalToConstant: 24), forward.widthAnchor.constraint(equalToConstant: 24),
            nav.trailingAnchor.constraint(equalTo: search.leadingAnchor, constant: -6),
            nav.centerYAnchor.constraint(equalTo: centerYAnchor),
            nav.leadingAnchor.constraint(greaterThanOrEqualTo: context.trailingAnchor, constant: 12),
            tools.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 6),
            tools.centerYAnchor.constraint(equalTo: centerYAnchor),
            awake.widthAnchor.constraint(equalToConstant: 28),   // the three cups differ in width; the search mustn't shift
            sideBySide.widthAnchor.constraint(equalToConstant: 28),
            tools.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48)   // clear of the inspector toggle
        ])
        followModel()
    }

    /// Sets up what the bar follows: the workspace, its branch and CI, what runs, and the setting of each button.
    private func followModel() {
        let app = app   // the closures below read this local, as they read the initializer's parameter
        track(owner: self) {
            app.extensions.all.runs != nil
        } changed: { [weak self] _ in
            self?.placeRunParts()
        }
        track(owner: self) {
            [-1, 1].map { step in
                app.workbench.visit(step).flatMap { app.worktree(app.workbench.history.visits[$0]) }.flatMap {
                    app.groupName($0) ?? app.projectName($0.repoId)
                }
            }
        } changed: { [weak self] in
            self?.showNav(back: $0[0], forward: $0[1])
        }
        track(owner: self) { [app] in
            WindowBar.awakeMode(app)
        } changed: { [weak self] in
            self?.showAwake($0)
        }
        track(owner: self) {
            app.workbench.sideBySide
        } changed: { [weak self] in
            self?.showSideBySide($0)
        }
        track(owner: self) { [app] in
            app.settings[SettingKeys.sideBySideButton]
                && WindowBar.liveAgents(app, in: app.workbench.mainWorkspaceId) >= 2
        } changed: { [weak self] in
            self?.sideBySide.isHidden = !$0
        }
        track(owner: self) {
            app.themes.chromeText
        } changed: { [weak self] _ in
            self?.name.font = .ui(TextSize.body, weight: .semibold)
            for chip in [self?.folder, self?.branch, self?.pr] { chip?.font = .ui(TextSize.row) }
            self?.update()
        }
        // A branch switched anywhere (in a terminal too) moves the workspace's refs, and the daemon pushes the change.
        track(owner: self) { [weak self] in
            Values(
                app.workbench.page == nil ? app.worktree(app.workbench.mainWorkspaceId) : nil,
                app.arrangement.projectLook, self?.info, self?.dirty ?? false, self?.syncing, self?.prMark?.tip,
                [self?.fetchTrouble?.said, self?.fetchTrouble?.mark],
                self.map { ["\($0.ci?.state.rawValue ?? -1)", "\($0.ci?.atEnd ?? false)", $0.ciLine ?? ""] } ?? [])
        } changed: { [weak self] _ in
            self?.update()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// When room is short, the parts that can shorten themselves do (the page's address comes down to its port).
    override func layout() {
        super.layout()
        for part in runParts { part.fit(barWidth: bounds.width) }
    }

    /// Places the run parts as the extensions have them now. There are none while the built-in that has them is off.
    private func placeRunParts() {
        for part in runParts { part.removeFromSuperview() }
        runParts = app.extensions.all.runs?.bar() ?? []
        for (index, part) in runParts.enumerated() {
            tools.insertArrangedSubview(part, at: index)
            tools.setCustomSpacing(6, after: part)
        }
        needsLayout = true
    }

    /// The chip's title, cut in its middle when short of room. Centred, as a plain title is: a paragraph style without
    /// an alignment sets the title left, and the glyph then leaves its slot, where the CI mark stands over it.
    static func cutInMiddle(_ title: NSMutableAttributedString) -> NSAttributedString {
        let cut = NSMutableParagraphStyle()
        cut.lineBreakMode = .byTruncatingMiddle
        cut.alignment = .center
        title.addAttribute(.paragraphStyle, value: cut, range: NSRange(location: 0, length: title.length))
        return title
    }

    /// Makes a capsule that greys in under the pointer and springs when clicked (`PointerButton`), instead of AppKit's
    /// outline.
    static func chip(_ symbol: String?) -> NSButton {
        let button = PointerButton(frame: .zero)
        button.radius = nil
        button.padding = chipPadding
        button.font = .ui(TextSize.row)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        if let symbol {
            button.image = Glyph.image(symbol, size: 13) ?? .symbol(symbol, "")
            button.symbolConfiguration = .chrome(Metrics.iconSmall)
        }
        return button
    }

    private func update() {
        guard let worktree else {
            context.isHidden = true
            return
        }
        context.isHidden = false
        if let repo = app.repo(worktree.repoId) {
            ProjectIcon.show(repo.path, in: icon, app: app)
        } else {
            icon.image = nil
        }
        name.stringValue = app.groupName(worktree) ?? ""   // a project's own screen has no name; the folder says it
        name.isHidden = name.stringValue.isEmpty
        // Show the project's folder name, as Xcode and Finder name a project, also on a branch. A branch folder's own
        // name tells no more than the branch's first word, and the chip beside it shows the real branch. The whole
        // path is in the tooltip and the menu.
        let place =
            app.repo(worktree.repoId).map(app.projectPlace) ?? (worktree.path as NSString).abbreviatingWithTildeInPath
        let path =
            worktree.path == app.repo(worktree.repoId)?.path
            ? place : (worktree.path as NSString).abbreviatingWithTildeInPath
        folder.title =
            NoProject.holds(app.repo(worktree.repoId))
            ? app.projectName(worktree.repoId) ?? "" : (place as NSString).lastPathComponent
        folder.toolTip = path + "\n" + String(localized: "Open In, Reveal in Finder, Copy Path")
        branch.isHidden = info == nil
        if let info { showBranch(info) }
        let badge = prMark
        pr.isHidden = badge == nil
        if let badge {
            pr.attributedTitle = badge.title
            pr.toolTip = badge.tip + "\n" + SidebarCell.onGitHub
        }
    }

    @objc private func folderMenu() {
        guard let path = worktree?.path else { return }
        let menu = NSMenu()
        WorkspaceActions.addOpenIn(to: menu, path: { path })
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let host = WorkspaceActions.onHost(path)
        if host == nil {   // a remote project's local folder holds only its marker, so it has no Finder item
            menu.add(String(localized: "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        menu.add(String(localized: "Copy Path")) { WorkspaceActions.copyPath(path) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: folder.bounds.height + 4), in: folder)
    }

    /// Shows the branch, what is left to pull (in the text's colour: news, not a call) and to push (in the accent: what
    /// you can do), and a dot while there are uncommitted changes. Orange stays for what waits for you.
    /// The sync arrows replace the branch glyph while a pull, push or fetch runs, and otherwise the CI's mark can go
    /// there (or after the counts). With no upstream, it shows only what publishing would push.
    private func showBranch(_ info: BranchInfo) {
        let ahead = info.ahead ?? 0, behind = info.upstream == nil ? 0 : info.behind ?? 0
        let font = NSFont.ui(TextSize.row)
        let name = event?.branchTitle ?? info.current ?? info.head ?? "HEAD"   // a folder of repositories: theirs
        let title = NSMutableAttributedString(
            string: name,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        for (arrow, commits, color) in [("arrow.down", behind, NSColor.labelColor), ("arrow.up", ahead, .emphasis)]
        where commits > 0 {
            title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            title.append(.signed(arrow, commits, size: TextSize.row, color: color))
        }
        if dirty {
            title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            title.append(SidebarCell.dot(shared: false))   // the sidebar's changes dot, drawn
        }
        let trouble = fetchTrouble
        if let mark = trouble?.mark {   // the background fetch has failed for an hour: grey, a shape, not a colour
            title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            title.append(.signed(mark, nil, size: TextSize.row, color: .secondaryLabelColor))
        }
        let running = syncing, ci = self.ci?.state, atEnd = self.ci?.atEnd == true,
            inPlace = ci != nil && !atEnd && running == nil
        if atEnd {
            let room = NSTextAttachment()
            room.image = CIMarkSlot.room(12)
            title.append(NSAttributedString(string: " "))
            title.append(NSAttributedString(attachment: room))
        }
        // Short of room, a long name loses its middle: both its ends tell branches apart, and the counts and the dot
        // after it stay, because they are the title's end.
        branch.attributedTitle = Self.cutInMiddle(title)
        ciMark.state = atEnd || inPlace ? ci : nil
        ciAtStart.isActive = inPlace
        ciAtEnd.isActive = atEnd
        let changed = app.latest(GitEvent.self, app.gitKey(app.workbench.mainWorkspaceId))?.changes?.count ?? 0
        let parts =
            [name] + (behind > 0 ? [String(localized: "\(behind) to pull")] : [])
            + (ahead > 0 ? [String(localized: "\(ahead) to push")] : [])
            + (changed > 0 ? [String(localized: "\(changed) changed")] : [])
            + [trouble?.said].compactMap { $0 }
        let said = ciLine
        branch.toolTip = parts.joined(separator: " · ") + (said.map { "\n" + $0 } ?? "")
        branch.image =
            running != nil
            ? .symbol("arrow.up.arrow.down", running ?? "")   // Pull's and Push's arrows, the git family's
            : inPlace
                ? CIMarkSlot.room(13)
                : Glyph.image("arrow.triangle.branch", size: 13) ?? .symbol("arrow.triangle.branch", "")
        // VoiceOver hears the counts the tooltip shows, so a zero isn't said either.
        let branchWords = [String(localized: "Branch \(info.current ?? "HEAD")")] + parts.dropFirst()
        branch.setAccessibilityLabel(running ?? (branchWords + [said].compactMap { $0 }).joined(separator: ", "))
    }

    @objc private func branchClicked() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Within 0.25 s of the popover closing, this click is the one that closed it.
        guard let wid = worktree?.id, Date().timeIntervalSince(closedAt) > 0.25 else { return }
        guard let vc = app.extensions.all.branch?.popover(wid, popover) else { return }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = vc
        popover.show(relativeTo: branch.bounds, of: branch, preferredEdge: .maxY)
    }

}

extension WindowBar: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) { closedAt = Date() }
}

extension WindowBar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === branch.menu { branchItems(menu) } else { placeItems(menu, step: menu === back.menu ? -1 : 1) }
    }

    /// The branch chip's menu: the name, then the built-in's items (Create Pull Request, where its CI shows).
    func branchItems(_ menu: NSMenu) {
        let app = app
        if let name = info?.current {
            menu.add(String(localized: "Copy Branch Name")) {
                copyText(name)
            }
        }
        app.extensions.all.ci?.menu(menu, worktree?.id)
    }

    /// The list behind Back or Forward: the places in that direction, nearest first, as a browser's arrows list them.
    private func placeItems(_ menu: NSMenu, step: Int) {
        let app = app
        for (index, name) in app.workbench.places(step).prefix(10) { menu.add(name) { app.workbench.go(to: index) } }
    }
}
