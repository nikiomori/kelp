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
    private let folder = WindowBar.chip(nil), branch = WindowBar.chip("arrow.triangle.branch"), pr = WindowBar.chip("arrow.triangle.pull")
    private let search: SearchPill
    private let app: AppModel
    private let back = NSButton.titlebar("chevron.left", String(localized: "Back"), tip: "")
    private let forward = NSButton.titlebar("chevron.right", String(localized: "Forward"), tip: "")
    private let awake = NSButton.titlebar("cup.and.saucer", String(localized: "Keep Mac Awake"), tip: "")
    private let sideBySide = NSButton.titlebar("rectangle.split.3x1", String(localized: "Agents Side by Side"), tip: "")
    /// The branch chip: the workspace on screen's git, as the daemon pushes it (ChangedFiles watches it).
    private var info: BranchInfo? { app.git[app.workbench.workspaceId ?? ""]?.branches }

    /// Uncommitted changes in the workspace on screen (a dot on the chip), and what a sync running there says.
    private var dirty: Bool { !(app.git[app.workbench.workspaceId ?? ""]?.changes ?? []).isEmpty }
    private var syncing: String? { app.syncing[app.workbench.workspaceId ?? ""] }
    private let popover = NSPopover()
    private var closedAt = Date.distantPast

    private var worktree: Worktree? { app.worktree(app.workbench.workspaceId) }
    /// The folder the sidebar keeps the pull request for: a desk shares its project's.
    private var badgeFolder: Worktree? { worktree.flatMap { app.rowBadges.folder(workspace: $0.id) ?? app.rowBadges.folder(project: $0.repoId) } }

    init(app: AppModel) {
        self.app = app; search = SearchPill(app: app)
        super.init(frame: .zero)
        name.font = .ui(13, weight: .semibold); name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(450), for: .horizontal)
        folder.lineBreakMode = .byTruncatingMiddle; folder.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        folder.target = self
        folder.action = #selector(folderMenu)
        folder.toolTip = String(localized: "Open In, Reveal in Finder, Copy Path")
        branch.target = self
        branch.action = #selector(branchClicked)
        pr.target = self; pr.action = #selector(openPR)
        context.setViews([icon, name, folder, branch, pr], in: .leading)
        context.spacing = 2
        context.setCustomSpacing(7, after: icon)
        context.setCustomSpacing(6, after: name)
        context.setCustomSpacing(8, after: folder)
        awake.target = self; awake.action = #selector(toggleAwake)
        sideBySide.target = self; sideBySide.action = #selector(toggleSideBySide)
        let hide = NSMenu()
        hide.add(String(localized: "Hide Button")) { app.settings.set("workbench.sideBySideButton", .bool(false)) }
        sideBySide.menu = hide
        back.target = self
        back.action = #selector(goBack)
        forward.target = self
        forward.action = #selector(goForward)
        let nav = NSStackView(views: [back, forward]); nav.spacing = 0
        for v in [context, nav, search, awake, sideBySide] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        // Short of room, the search leaves the centre first, then narrows; only then does the path shorten, then the name.
        // All below the window's own size (500): a long path or name truncates instead of widening the window.
        let wide = search.widthAnchor.constraint(equalToConstant: 280); wide.priority = .init(250)
        let center = search.centerXAnchor.constraint(equalTo: centerXAnchor); center.priority = .init(200)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            context.centerYAnchor.constraint(equalTo: centerYAnchor), search.centerYAnchor.constraint(equalTo: centerYAnchor),
            search.heightAnchor.constraint(equalToConstant: 22), wide, center,
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120), search.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            back.widthAnchor.constraint(equalToConstant: 24), forward.widthAnchor.constraint(equalToConstant: 24),
            nav.trailingAnchor.constraint(equalTo: search.leadingAnchor, constant: -6), nav.centerYAnchor.constraint(equalTo: centerYAnchor),
            nav.leadingAnchor.constraint(greaterThanOrEqualTo: context.trailingAnchor, constant: 12),
            awake.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 6), awake.centerYAnchor.constraint(equalTo: centerYAnchor),
            awake.widthAnchor.constraint(equalToConstant: 28),   // the three cups differ in width; the search mustn't shift
            sideBySide.leadingAnchor.constraint(equalTo: awake.trailingAnchor, constant: 2), sideBySide.centerYAnchor.constraint(equalTo: centerYAnchor),
            sideBySide.widthAnchor.constraint(equalToConstant: 28),
            sideBySide.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48)   // clear of the inspector toggle
        ])
        track(owner: self) {
            [-1, 1].map { app.workbench.visit($0).flatMap { app.worktree(app.workbench.history.visits[$0])?.displayName } }
        } changed: { [weak self] in
            self?.showNav(back: $0[0], forward: $0[1])
        }
        track(owner: self) { [app] in WindowBar.awakeMode(app) } changed: { [weak self] in self?.showAwake($0) }
        track(owner: self) { app.workbench.sideBySide } changed: { [weak self] in self?.showSideBySide($0) }
        track(owner: self) { app.settings.bool("workbench.sideBySideButton") ?? true } changed: { [weak self] in self?.sideBySide.isHidden = !$0 }
        track(owner: self) { app.worktree(app.workbench.workspaceId) } changed: { [weak self] _ in self?.update() }
        // A branch switched anywhere (a terminal too) moves the workspace's refs: the daemon pushes it.
        track(owner: self) { [weak self] in self?.info } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [weak self] in self?.dirty ?? false } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [weak self] in self?.syncing } changed: { [weak self] _ in self?.update() }
        track(owner: self) { app.rowBadges.prs } changed: { [weak self] _ in self?.update() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func chip(_ symbol: String?) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.bezelStyle = .recessed; b.showsBorderOnlyWhileMouseInside = true
        b.font = .ui(12)
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        if let symbol { b.image = Glyph.image(symbol, size: 13) ?? .symbol(symbol, ""); b.symbolConfiguration = .init(pointSize: 11, weight: .regular) }
        return b
    }

    private func update() {
        guard let w = worktree else { context.isHidden = true; return }
        context.isHidden = false
        if let r = app.repo(w.repoId) { ProjectIcon.show(r.path, in: icon, app: app) } else { icon.image = nil }
        name.stringValue = w.displayName
        folder.title = (w.path as NSString).abbreviatingWithTildeInPath
        branch.isHidden = info == nil
        if let info { showBranch(info) }
        let p = badgeFolder.flatMap { RowBadges.pr(app.rowBadges.prs[$0.id]) }
        pr.isHidden = p == nil
        if let p { pr.attributedTitle = p.0; pr.toolTip = p.1 }
    }

    @objc private func folderMenu() {
        guard let path = worktree?.path else { return }
        let m = NSMenu()
        WorkspaceActions.addOpenIn(to: m, path: path)
        if !m.items.isEmpty { m.addItem(.separator()) }
        m.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        m.add(String(localized: "Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: folder.bounds.height + 4), in: folder)
    }

    /// The branch, what is left to pull (orange) and push (blue), a dot while there are uncommitted changes; the sync arrows
    /// instead of the branch glyph while a pull, push or fetch runs. No upstream: only what publishing would push.
    private func showBranch(_ info: BranchInfo) {
        let ahead = info.ahead ?? 0, behind = info.upstream == nil ? 0 : info.behind ?? 0
        let font = NSFont.ui(12), count = NSFont.ui(12, weight: .semibold)
        let t = NSMutableAttributedString(string: info.current ?? info.head ?? "HEAD", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if behind > 0 { t.append(NSAttributedString(string: "  ↓\(behind)", attributes: [.font: count, .foregroundColor: NSColor.textOrange])) }
        if ahead > 0 { t.append(NSAttributedString(string: "  ↑\(ahead)", attributes: [.font: count, .foregroundColor: NSColor.controlAccentColor])) }
        if dirty { t.append(NSAttributedString(string: "  •", attributes: [.font: count, .foregroundColor: NSColor.secondaryLabelColor])) }
        branch.attributedTitle = t
        let changed = app.git[app.workbench.workspaceId ?? ""]?.changes?.count ?? 0
        let parts = [info.current ?? info.head ?? "HEAD"] + (ahead > 0 ? [String(localized: "\(ahead) to push")] : [])
            + (behind > 0 ? [String(localized: "\(behind) to pull")] : []) + (changed > 0 ? [String(localized: "\(changed) changed")] : [])
        branch.toolTip = parts.joined(separator: " · ")
        let running = syncing
        branch.image = running == nil ? (Glyph.image("arrow.triangle.branch", size: 13) ?? .symbol("arrow.triangle.branch", ""))
                                      : .symbol("arrow.triangle.2.circlepath", running ?? "")
        branch.setAccessibilityLabel(running ?? String(localized: "Branch \(info.current ?? "HEAD"), \(behind) to pull, \(ahead) to push"))
    }

    @objc private func branchClicked() {
        if popover.isShown { popover.performClose(nil); return }
        guard let wid = worktree?.id, Date().timeIntervalSince(closedAt) > 0.25 else { return }   // else this click closed it
        let vc = SyncPopover(app: app, worktree: wid)
        vc.popover = popover
        popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = vc
        popover.show(relativeTo: branch.bounds, of: branch, preferredEdge: .maxY)
    }

    /// The setting ("always", "agents", "off"), or "working": agents keep the Mac awake right now (as the daemon counts them).
    private static func awakeMode(_ app: AppModel) -> String {
        let mode = app.settings.string("power.keepAwake") ?? "agents"
        let working = app.sessions.contains { $0.agent != "shell" && $0.status == .working }
        return mode == "agents" && working ? "working" : mode
    }

    /// The cup right of the search, always there so the switch can be found: empty while the Mac may sleep, steaming while
    /// agents keep it awake, orange while it's on for good. A click is Keep Mac Awake (also in the Tools menu); a right-click
    /// picks the mode.
    private func showAwake(_ mode: String) {
        let app = self.app
        let (symbol, tip) = switch mode {
        case "always": ("cup.and.heat.waves.fill", String(localized: "The Mac stays awake until you click here"))
        case "working": ("cup.and.heat.waves", String(localized: "The Mac stays awake while agents work. Click to keep it awake always"))
        default: ("cup.and.saucer", String(localized: "The Mac can sleep. Click to keep it awake"))
        }
        let cup = NSImage.symbol(symbol, String(localized: "Keep Mac Awake"))   // a recessed button ignores contentTintColor
        awake.image = mode == "always" ? cup.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) : cup
        awake.toolTip = tip
        let m = NSMenu()
        for (v, title) in [("agents", String(localized: "While agents work")), ("always", String(localized: "Always")), ("off", String(localized: "Never"))] {
            m.add(title) { app.settings.set("power.keepAwake", .string(v)) }.state = (mode == "working" ? "agents" : mode) == v ? .on : .off
        }
        awake.menu = m
    }

    /// The arrows say where they go; with nothing that way they grey out.
    private func showNav(back to: String?, forward ahead: String?) {
        for (b, name, title, key) in [(back, to, String(localized: "Back"), "⌃⌘←"), (forward, ahead, String(localized: "Forward"), "⌃⌘→")] {
            b.isEnabled = name != nil
            b.toolTip = name.map { "\(title): \($0) (\(key))" } ?? "\(title) (\(key))"
        }
    }
    @objc private func goBack() { app.workbench.goBack(-1) }
    @objc private func goForward() { app.workbench.goBack(1) }

    @objc private func toggleAwake() { app.extensions.command("power.keepAwake")?.run([:]) }

    /// Filled while the workspace puts its agents side by side; a click shows them as tabs in one pane, and back.
    /// A right-click hides it (Settings › Appearance brings it back).
    private func showSideBySide(_ on: Bool) {
        sideBySide.image = .symbol(on ? "rectangle.split.3x1.fill" : "rectangle.split.3x1", String(localized: "Agents Side by Side"))
        sideBySide.toolTip = on ? String(localized: "Agents side by side. Click to show them as tabs (⌃⌘T)")
                                : String(localized: "Agents as tabs. Click to put them side by side (⌃⌘T)")
    }
    @objc private func toggleSideBySide() { app.extensions.command("agents.sideBySide")?.run([:]) }

    @objc private func openPR() {
        guard let w = badgeFolder, let u = app.rowBadges.prs[w.id]?.url else { return }
        app.workbench.open(u, workspace: worktree?.id)
    }
}

extension WindowBar: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) { closedAt = Date() }
}

/// Open Quickly as a place to click: it looks like a search field and opens the ⌘P palette (files, agents, commands).
@MainActor
final class SearchPill: NSControl {
    private let glass = NSImageView(image: .symbol("magnifyingglass", ""))
    private let label = NSTextField(labelWithString: ""), key = NSTextField(labelWithString: "⌘P")
    private let full = String(localized: "Files, agents, commands"), short = String(localized: "Search")
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        glass.symbolConfiguration = .init(pointSize: 11, weight: .regular); glass.contentTintColor = .secondaryLabelColor
        label.font = .ui(12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        key.font = .ui(11); key.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [glass, label, NSView(), key]); row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 10)
        pin(row)
        toolTip = String(localized: "Open Quickly (⌘P)")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Open Quickly"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = NSColor.fillRest.cgColor }
    override var wantsUpdateLayer: Bool { true }
    override func layout() {
        super.layout(); layer?.cornerRadius = bounds.height / 2
        // Short of room, "Search" rather than "Files, a…". The room is the pill's, so the choice doesn't feed back on itself.
        let room = bounds.width - 19 - glass.frame.width - key.frame.width - 18
        let text = (full as NSString).size(withAttributes: [.font: label.font ?? .ui(12)]).width <= room ? full : short
        if label.stringValue != text { label.stringValue = text }
    }
    /// The whole pill takes the click; in the title bar its label would move the window instead.
    override func hitTest(_ p: NSPoint) -> NSView? { super.hitTest(p) == nil ? nil : self }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The palettes grow out of it (QuickOpen.present).
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { app.quickOpen.anchor = self } }
    override func mouseDown(with e: NSEvent) { app.quickOpen.show(commandsOnly: false) }
    override func accessibilityPerformPress() -> Bool { app.quickOpen.show(commandsOnly: false); return true }
}
