import AppKit
import Core
import DesignKit

/// The window's first row, the title bar: where you are — the workspace, its folder (Open In, Finder, Copy Path), its
/// branch and pull request — and Open Quickly (⌘P) in the middle, Back / Forward beside it. The window controller puts the panel toggles in the
/// corners and lines the workspace up with the editor area; the panes' tab strips are the second row.
@MainActor
final class WindowBar: NSView {
    /// The system title bar's height (28 pt before macOS 26, 32 after): the traffic lights sit on its centre line.
    static let height = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height

    /// Icon, name, folder, branch, pull request; hidden without a workspace.
    let context = NSStackView()
    private let icon = NSImageView(), name = NSTextField(labelWithString: "")
    private let folder = WindowBar.chip(nil), branch = WindowBar.chip("arrow.triangle.branch"),
        pr = WindowBar.chip("arrow.triangle.pull")
    private let search: SearchPill
    private let run: RunChip, page: PageChip
    private let app: AppModel
    private let back = NSButton.titlebar("chevron.left", String(localized: "Back"), tip: "")
    private let forward = NSButton.titlebar("chevron.right", String(localized: "Forward"), tip: "")
    private let awake = NSButton.titlebar("cup.and.saucer", String(localized: "Keep Mac Awake"), tip: "")
    private let sideBySide = NSButton.titlebar("rectangle.split.3x1", String(localized: "Agents Side by Side"), tip: "")
    /// The branch chip: the workspace on screen's git, as the daemon pushes it (ChangedFiles watches it).
    private var info: BranchInfo? { app.latest(GitEvent.self, app.workbench.workspaceId ?? "")?.branches }

    /// Uncommitted changes in the workspace on screen (a dot on the chip), and what a sync running there says.
    private var dirty: Bool { !(app.latest(GitEvent.self, app.workbench.workspaceId ?? "")?.changes ?? []).isEmpty }
    private var syncing: String? { app.workbench.workspaceId.flatMap { app.extensions.all.branch?.running($0) } }
    private let popover = NSPopover()
    private var closedAt = Date.distantPast

    /// None over a page: the project and branch beside it would be the workspace's behind it.
    private var worktree: Worktree? { app.workbench.page == nil ? app.worktree(app.workbench.workspaceId) : nil }
    /// The folder the sidebar keeps the pull request and CI for: a workspace shares its project's.
    private var badgeFolder: Worktree? { app.rowBadges.folder(of: app.workbench.workspaceId) }
    /// The branch's CI on the chip (Settings › Appearance › CI): in place of the branch glyph, after the counts, or not at all.
    private let ciMark = CIMark()
    /// Centred on the glyph's slot (the chip's padding, then 13 pt) or on the room left at the title's end (12 pt).
    private lazy var ciAtStart = ciMark.centerXAnchor.constraint(
        equalTo: branch.leadingAnchor, constant: Self.chipPadding + 13 / 2)
    private lazy var ciAtEnd = ciMark.centerXAnchor.constraint(
        equalTo: branch.trailingAnchor, constant: -(Self.chipPadding + 12 / 2))
    private static let chipPadding: CGFloat = 6
    /// The mark and its place, from the built-in that has CI (`FolderCI`); none, and the chip shows no CI.
    private var ci: (state: CIRuns.State, atEnd: Bool)? { badgeFolder.flatMap { app.extensions.all.ci?.chip($0.id) } }
    /// "CI: Failed · Tests" for the tooltip and VoiceOver, whatever the chip shows.
    private var ciLine: String? { badgeFolder.flatMap { app.extensions.all.ci?.line($0.id) } }

    init(app: AppModel) {
        self.app = app
        search = SearchPill(app: app)
        run = RunChip(app: app)
        page = PageChip(app: app)
        super.init(frame: .zero)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(450), for: .horizontal)
        folder.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        folder.target = self
        folder.action = #selector(folderMenu)
        folder.toolTip = String(localized: "Open In, Reveal in Finder, Copy Path")
        branch.target = self
        branch.action = #selector(branchClicked)
        branch.addSubview(ciMark)
        ciMark.centerYAnchor.constraint(equalTo: branch.centerYAnchor).isActive = true
        pr.target = self
        pr.action = #selector(openPR)
        for chip in [branch, back, forward] {
            chip.menu = NSMenu()
            chip.menu?.delegate = self
        }
        context.setViews([icon, name, folder, branch, pr], in: .leading)
        context.spacing = 2
        context.setCustomSpacing(7, after: icon)
        context.setCustomSpacing(6, after: name)
        context.setCustomSpacing(8, after: folder)
        awake.target = self
        awake.action = #selector(toggleAwake)
        sideBySide.target = self
        sideBySide.action = #selector(toggleSideBySide)
        let hide = NSMenu()
        Self.addHide(to: hide, "workbench.sideBySideButton", app)
        sideBySide.menu = hide
        back.target = self
        back.action = #selector(goBack)
        forward.target = self
        forward.action = #selector(goForward)
        let nav = NSStackView(views: [back, forward])
        nav.spacing = 0
        // Right of the search: what runs here (gone while the project offers nothing), the page it serves, the cup, and side
        // by side (with two agents or more).
        let tools = NSStackView(views: [run, page, awake, sideBySide])
        tools.spacing = 2
        tools.detachesHiddenViews = true
        tools.setCustomSpacing(6, after: run)
        tools.setCustomSpacing(6, after: page)
        for part in [context, nav, search, tools] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        // Short of room, the search leaves the centre first, then narrows; only then does the path shorten, then the name.
        // All below the window's own size (500): a long path or name truncates instead of widening the window.
        let wide = search.widthAnchor.constraint(equalToConstant: 280)
        wide.priority = .init(250)
        let center = search.centerXAnchor.constraint(equalTo: centerXAnchor)
        center.priority = .init(200)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            context.centerYAnchor.constraint(equalTo: centerYAnchor),
            search.centerYAnchor.constraint(equalTo: centerYAnchor),
            search.heightAnchor.constraint(equalToConstant: 22), wide, center,
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

    /// What the bar follows: the workspace, its branch and CI, what runs, the setting of each button.
    private func followModel() {
        let app = app   // what the closures below read, as the initializer's parameter was
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
            app.settings.bool("workbench.sideBySideButton") != false
                && WindowBar.liveAgents(app, in: app.workbench.workspaceId) >= 2
        } changed: { [weak self] in
            self?.sideBySide.isHidden = !$0
        }
        track(owner: self) {
            app.themes.chromeText
        } changed: { [weak self] _ in
            self?.name.font = .ui(13, weight: .semibold)
            for chip in [self?.folder, self?.branch, self?.pr] { chip?.font = .ui(12) }
            self?.update()
        }
        track(owner: self) {
            app.workbench.page == nil ? app.worktree(app.workbench.workspaceId) : nil
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) {
            app.projectLook
        } changed: { [weak self] _ in
            self?.update()
        }
        // A branch switched anywhere (a terminal too) moves the workspace's refs: the daemon pushes it.
        track(owner: self) { [weak self] in
            self?.info
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [weak self] in
            self?.dirty ?? false
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [weak self] in
            self?.syncing
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) {
            app.rowBadges.prs
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [weak self] in
            self.map { ["\($0.ci?.state.rawValue ?? -1)", "\($0.ci?.atEnd ?? false)", $0.ciLine ?? ""] } ?? []
        } changed: { [weak self] _ in
            self?.update()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Short of room the page's address comes down to its port. The bar's own width, so the choice can't feed back on itself.
    override func layout() {
        super.layout()
        page.compact = bounds.width < 900
    }

    /// A capsule that greys in under the pointer and springs when clicked (`PointerButton`), not AppKit's outline.
    private static func chip(_ symbol: String?) -> NSButton {
        let button = PointerButton(frame: .zero)
        button.radius = nil
        button.padding = chipPadding
        button.font = .ui(12)
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
        name.stringValue = app.groupName(worktree) ?? ""   // a project's own screen: the folder beside it says it
        name.isHidden = name.stringValue.isEmpty
        // The project's folder, as Xcode and Finder name a project, on a branch too: its own folder's name is no more than
        // the branch's first one, beside the chip with the real one. The whole path in its tooltip and its menu.
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
        let badge = badgeFolder.flatMap { RowBadges.pr(app.rowBadges.prs[$0.id]) }
        pr.isHidden = badge == nil
        if let badge {
            pr.attributedTitle = badge.0
            pr.toolTip = badge.1
        }
    }

    @objc private func folderMenu() {
        guard let path = worktree?.path else { return }
        let menu = NSMenu()
        WorkspaceActions.addOpenIn(to: menu, path: path)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.add(String(localized: "Reveal in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        menu.add(String(localized: "Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: folder.bounds.height + 4), in: folder)
    }

    /// The branch, what is left to pull (orange) and push (blue), a dot while there are uncommitted changes; the sync arrows
    /// instead of the branch glyph while a pull, push or fetch runs, else the CI's mark there (or after the counts). No
    /// upstream: only what publishing would push.
    private func showBranch(_ info: BranchInfo) {
        let ahead = info.ahead ?? 0, behind = info.upstream == nil ? 0 : info.behind ?? 0
        let font = NSFont.ui(12), count = NSFont.ui(12, weight: .semibold)
        let title = NSMutableAttributedString(
            string: info.current ?? info.head ?? "HEAD",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if behind > 0 {
            title.append(
                NSAttributedString(
                    string: "  ↓\(behind)", attributes: [.font: count, .foregroundColor: NSColor.textOrange]))
        }
        if ahead > 0 {
            title.append(
                NSAttributedString(
                    string: "  ↑\(ahead)", attributes: [.font: count, .foregroundColor: NSColor.emphasis]))
        }
        if dirty {
            title.append(
                NSAttributedString(
                    string: "  •", attributes: [.font: count, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let running = syncing, ci = self.ci?.state, atEnd = self.ci?.atEnd == true,
            inPlace = ci != nil && !atEnd && running == nil
        if atEnd {
            let room = NSTextAttachment()
            room.image = CIMark.room(12)
            title.append(NSAttributedString(string: " "))
            title.append(NSAttributedString(attachment: room))
        }
        branch.attributedTitle = title
        ciMark.state = atEnd || inPlace ? ci : nil
        ciAtStart.isActive = inPlace
        ciAtEnd.isActive = atEnd
        let changed = app.latest(GitEvent.self, app.workbench.workspaceId ?? "")?.changes?.count ?? 0
        let parts =
            [info.current ?? info.head ?? "HEAD"] + (ahead > 0 ? [String(localized: "\(ahead) to push")] : [])
            + (behind > 0 ? [String(localized: "\(behind) to pull")] : [])
            + (changed > 0 ? [String(localized: "\(changed) changed")] : [])
        let said = ciLine
        branch.toolTip = parts.joined(separator: " · ") + (said.map { "\n" + $0 } ?? "")
        branch.image =
            running != nil
            ? .symbol("arrow.triangle.2.circlepath", running ?? "")
            : inPlace
                ? CIMark.room(13)
                : Glyph.image("arrow.triangle.branch", size: 13) ?? .symbol("arrow.triangle.branch", "")
        let branchWords = String(localized: "Branch \(info.current ?? "HEAD"), \(behind) to pull, \(ahead) to push")
        branch.setAccessibilityLabel(running ?? ([branchWords] + [said].compactMap { $0 }).joined(separator: ", "))
    }

    @objc private func branchClicked() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let wid = worktree?.id, Date().timeIntervalSince(closedAt) > 0.25 else { return }   // else this click closed it
        guard let vc = app.extensions.all.branch?.popover(wid, popover) else { return }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = vc
        popover.show(relativeTo: branch.bounds, of: branch, preferredEdge: .maxY)
    }

    /// The setting ("always", "agents", "off"), or "working": agents keep the Mac awake right now (as the daemon counts them).
    /// "hidden" once the button's right-click hid it, whatever the mode.
    private static func awakeMode(_ app: AppModel) -> String {
        let mode = app.settings.string("power.keepAwake") ?? "agents"
        let working = app.sessions.contains { $0.isChat && $0.status == .working }
        return app.settings.bool("workbench.awakeButton") == false
            ? "hidden" : mode == "agents" && working ? "working" : mode
    }

    /// The cup right of the search, always there so the switch can be found: empty while the Mac may sleep, steaming while
    /// agents keep it awake, orange while it's on for good. A click is Keep Mac Awake (also in the Tools menu); a right-click
    /// picks the mode or hides it.
    private func showAwake(_ mode: String) {
        let app = self.app
        awake.isHidden = mode == "hidden"
        let (symbol, tip) =
            switch mode {
            case "always": ("cup.and.heat.waves.fill", String(localized: "The Mac stays awake until you click here"))
            case "working":
                (
                    "cup.and.heat.waves",
                    String(localized: "The Mac stays awake while agents work. Click to keep it awake always")
                )
            default: ("cup.and.saucer", String(localized: "The Mac can sleep. Click to keep it awake"))
            }
        let cup = NSImage.symbol(symbol, String(localized: "Keep Mac Awake"))   // a recessed button ignores contentTintColor
        awake.image = mode == "always" ? cup.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) : cup
        awake.toolTip = tip
        let menu = NSMenu()
        for (choice, title) in [
            ("agents", String(localized: "While agents work")), ("always", String(localized: "Always")),
            ("off", String(localized: "Never"))
        ] {
            menu.add(title) { app.settings.set("power.keepAwake", .string(choice)) }.state =
                (mode == "working" ? "agents" : mode) == choice ? .on : .off
        }
        menu.addItem(.separator())
        Self.addHide(to: menu, "workbench.awakeButton", app)
        awake.menu = menu
    }

    /// A title-bar button's right-click: off by its setting, which Settings › Window turns back on.
    private static func addHide(to menu: NSMenu, _ key: String, _ app: AppModel) {
        menu.add(String(localized: "Hide Button")) {
            app.settings.set(key, .bool(false))
            Banner.show(String(localized: "The button is hidden. Settings › Window brings it back."))
        }
    }

    /// Agents that tile side by side in a workspace, as `EditorArea.arrange` picks them: below two the button does nothing.
    static func liveAgents(_ app: AppModel, in wid: String?) -> Int {
        app.sessions.filter {
            $0.worktreeId == wid && !["shell", "custom"].contains($0.agent) && ![.exited, .paused].contains($0.status)
        }.count
    }

    /// The arrows say where they go; with nothing that way they grey out.
    private func showNav(back to: String?, forward ahead: String?) {
        for (arrow, name, title, key) in [
            (back, to, String(localized: "Back"), "⌃⌘←"), (forward, ahead, String(localized: "Forward"), "⌃⌘→")
        ] {
            arrow.isEnabled = name != nil
            arrow.toolTip = name.map { "\(title): \($0) (\(key))" } ?? "\(title) (\(key))"
        }
    }
    @objc private func goBack() { app.workbench.goBack(-1) }
    @objc private func goForward() { app.workbench.goBack(1) }

    @objc private func toggleAwake() { app.extensions.command("power.keepAwake")?.run([:]) }

    /// Pressed in (the selected fill) while the workspace puts its agents side by side; a click shows them as tabs in one
    /// pane, and back. Only with two agents or more; a right-click hides it (Settings › Window brings it back).
    /// On: the filled symbol in the accent (the label colour with Graphite) on the chosen grey, as a toggled toolbar
    /// button; off: its outline alone. The grey by itself read as the pointer's.
    private func showSideBySide(_ on: Bool) {
        let image = NSImage.symbol(
            on ? "rectangle.split.3x1.fill" : "rectangle.split.3x1", String(localized: "Agents Side by Side"))
        sideBySide.image = on ? image.withSymbolConfiguration(.init(paletteColors: [.emphasis])) : image   // a recessed button ignores contentTintColor
        sideBySide.restFill = on ? .fillSelected : nil
        sideBySide.toolTip =
            on
            ? String(localized: "Agents side by side. Click to show them as tabs (⌃⌘T)")
            : String(localized: "Agents as tabs. Click to put them side by side (⌃⌘T)")
    }
    @objc private func toggleSideBySide() { app.extensions.command("agents.sideBySide")?.run([:]) }

    @objc private func openPR() {
        guard let folder = badgeFolder, let url = app.rowBadges.prs[folder.id]?.url else { return }
        app.workbench.open(url, workspace: worktree?.id)
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

    /// The branch chip: the name, and where its CI shows.
    func branchItems(_ menu: NSMenu) {
        let app = app
        if let name = info?.current {
            menu.add(String(localized: "Copy Branch Name")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(name, forType: .string)
            }
        }
        if let worktree, app.rowBadges.prs[badgeFolder?.id ?? ""] == nil {
            menu.add(String(localized: "Create Pull Request…")) { PRActions(app).create(worktree: worktree.id) }
        }
        guard let ci = app.extensions.all.ci else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        ci.menu(menu)
    }

    /// Back's and Forward's list: the places that way, nearest first, as a browser's arrows hold them.
    private func placeItems(_ menu: NSMenu, step: Int) {
        let app = app
        for (index, name) in app.workbench.places(step).prefix(10) { menu.add(name) { app.workbench.go(to: index) } }
    }
}

/// Open Quickly as a place to click: it looks like a search field and opens the ⌘P palette (files, agents, commands).
@MainActor
final class SearchPill: PointerControl {
    private let glass = NSImageView(image: .symbol("magnifyingglass", ""))
    private let label = NSTextField(labelWithString: ""), key = NSTextField(labelWithString: "⌘P")
    private let full = String(localized: "Files, agents, commands"), short = String(localized: "Search")
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        restFill = .fillRest   // a field's ground; under the pointer a step darker, held darker still
        glass.symbolConfiguration = .chrome(Metrics.iconSmall)
        glass.contentTintColor = .secondaryLabelColor
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        key.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [glass, label, NSView(), key])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 10)
        pin(row)
        toolTip = String(localized: "Open Quickly (⌘P)")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Open Quickly"))
        track(owner: self) {
            app.themes.chromeText
        } changed: { [weak self] _ in
            self?.label.font = .ui(12)
            self?.key.font = .ui(11)
            self?.needsLayout = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        // Short of room, "Search" rather than "Files, a…". The room is the pill's, so the choice doesn't feed back on itself.
        let room = bounds.width - 19 - glass.frame.width - key.frame.width - 18
        let text = (full as NSString).size(withAttributes: [.font: label.font ?? .ui(12)]).width <= room ? full : short
        if label.stringValue != text { label.stringValue = text }
    }
    /// The whole pill takes the click; in the title bar its label would move the window instead.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    /// The palettes grow out of it (QuickOpen.present).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { app.quickOpen.anchor = self }
    }
    override func clicked() { app.quickOpen.show(commandsOnly: false) }
}
