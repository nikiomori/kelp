// The editor host: one editor area per recent workspace, and the welcome view shown with none.
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

/// Holds one editor area per recently used workspace, so switching back is instant (terminals stay attached).
@MainActor
final class EditorHost: NSViewController {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The card that holds the editor area (or the welcome), under the window bar, which lies over this view's top.
    private let card = Card()
    private var areas: [String: EditorArea] = [:]
    /// The main window's areas, latest first. An area in a window of its own isn't counted (it stays loaded).
    private var recent: [String] = []
    /// The editor area that has the keyboard: the main window's area, or that of a group in a window of its own.
    private(set) var current: EditorArea?
    /// The area the main window's card shows.
    private(set) var mainArea: EditorArea? {
        didSet { app.workbench.mainWorkspaceId = mainArea?.workspaceId }
    }
    /// Groups in windows of their own (`OwnWindow`).
    private var own: [String: OwnWindow] = [:]
    func ownWindow(_ id: String?) -> NSWindow? { id.flatMap { own[$0]?.window } }
    var ownWindowIds: [String] { Array(own.keys) }
    /// A workspace's editor area while it's loaded (because it was shown lately), on screen or not.
    func area(_ id: String) -> EditorArea? { areas[id] }
    var editedFiles: [SavableTab] { areas.values.flatMap(\.editedFiles) }
    func editedFiles(in ids: [String]) -> [SavableTab] { ids.compactMap { areas[$0] }.flatMap(\.editedFiles) }
    private var welcome: NSView?
    private static let keep = 4

    override func loadView() {
        let app = self.app
        view = NSView()
        view.pin(card, inset: NSEdgeInsets(top: WindowBar.height, left: Card.gap, bottom: Card.gap, right: Card.gap))
        card.identifier = Banner.anchor   // banners sit in the card's corner
        showWelcome()
        // Follow the daemon's state: workspaces that are gone leave, and sessions' tabs come and show their status and
        // context ring.
        track(owner: self) {
            Values(app.repos, app.worktrees, app.sessions, app.latest(ContextEvent.self).byKey)
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self) {
            app.themes.look
        } changed: { [weak self] in
            self?.card.look = $0
        }
    }

    /// While a panel slides beside the card, what the card shows takes the width it will have once the panel stands
    /// (`by` more than now), at once and only once, and the card uncovers or covers it. When it was laid out for every
    /// width on the way, each terminal drew itself anew on the main thread, a frame or two each time; when it kept its
    /// old width, its terminals rewrapped after the panel had stopped, a beat late. `trailing` is the edge that stays
    /// (the panel on the other side is moving).
    private var held: [WidthHold] = []
    func holdWidth(trailing: Bool, by change: CGFloat = 0) {
        letWidthGo()   // a slide cut short by another: the new one's width
        held = card.subviews.filter { $0.frame.width > 0 }.compactMap {
            WidthHold($0, in: card, edge: trailing ? .leading : .trailing, width: max(1, $0.frame.width + change))
        }
    }
    func letWidthGo() {
        held.forEach { $0.release() }
        held = []
    }

    /// Gives `id` the keyboard. A group in a window of its own comes to the front there. Any other workspace goes into
    /// the main window's card, and the main window comes to the front if a group's own window had the keys.
    func show(_ id: String?) {
        if let id, let window = own[id], let area = areas[id] {
            current = area
            window.showWindow(nil)
            area.focusSelected()
            return
        }
        let wasOwn = current != nil && current !== mainArea
        // What the card shows changes: the new group is in place at once, with a picture of the old one leaving on
        // top of it while the new one settles (`leave`, `settleIn`). Under Reduce Motion or off screen, there's no
        // picture and it just shows, as before.
        let picture = page != nil || mainArea?.workspaceId != id ? card.pictureForSwitch() : nil
        showInMain(id)
        if let picture {
            card.leave(picture)
            mainArea?.settleIn()
        }
        current = mainArea
        if wasOwn { view.window?.makeKeyAndOrderFront(nil) }
    }

    private func showInMain(_ id: String?) {
        if let previous = page {   // back from a page, the page goes (it reads its server only while it's there)
            previous.view.removeFromSuperview()
            page = nil
            if let shown = mainArea, shown.workspaceId == id {
                card.pin(shown.view)
                shown.focusSelected()
                return
            }
        }
        if let shown = mainArea, shown.workspaceId == id {
            shown.focusSelected()
            return
        }
        mainArea?.view.removeFromSuperview()
        guard let id, app.worktree(id) != nil else {
            mainArea = nil
            showWelcome()
            return
        }
        welcome?.removeFromSuperview()
        welcome = nil
        let area = loaded(id)
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        // The terminals of the evicted areas detach.
        let gone: [String]
        (recent, gone) = Self.evicting(recent, keep: Self.keep) { self.areas[$0]?.editedFiles.isEmpty == false }
        for old in gone {
            areas[old]?.removeFromParent()
            areas[old] = nil
        }
        mainArea = area
        card.pin(area.view)
        area.reconcile()
        area.focusSelected()
    }

    private func loaded(_ id: String) -> EditorArea {
        if let area = areas[id] { return area }
        let area = EditorArea(app: app, workspaceId: id)
        areas[id] = area
        addChild(area)
        return area
    }

    /// Moves `id` into a window of its own, with the keys. The main window shows `next` if it showed `id`.
    func moveToOwnWindow(_ id: String, next: String?) {
        guard own[id] == nil, app.worktree(id) != nil else { return }
        let area = loaded(id)
        recent.removeAll { $0 == id }
        if mainArea === area {
            area.view.removeFromSuperview()
            mainArea = nil
            showInMain(next)
        }
        let app = app
        let window = OwnWindow(app: app, name: "workspace." + id, content: area.view, beside: view.window) {
            app.worktree(id).map { app.groupName($0) ?? app.projectName($0.repoId) ?? $0.displayName }
        } becameKey: {
            app.workbench.ownWindowBecameKey(id)
        } closed: {
            app.workbench.returnToMain(id)
        }
        own[id] = window
        current = area
        area.reconcile()
        window.showWindow(nil)
        area.focusSelected()
    }

    /// Called when the own window of `id` closes. The area stays loaded, for the main window to show.
    func leaveOwnWindow(_ id: String) {
        guard let window = own.removeValue(forKey: id) else { return }
        areas[id]?.view.removeFromSuperview()
        recent.insert(id, at: 0)
        if current?.workspaceId == id { current = mainArea }
        window.close()
    }

    /// Called when a window got the keyboard, so its editor area is the one keys go to (nil means the main window).
    func becameKey(_ id: String?) { current = id.flatMap { own[$0] != nil ? areas[$0] : nil } ?? mainArea }

    /// What `showPage` shows in place of the workspace's area, which stays loaded behind it.
    private var page: TabContent?

    /// Shows a page made by its extension's tab provider, filling the card. Returns nil when no provider makes it.
    func showPage(_ uri: String) -> TabContent? {
        guard let made = app.extensions.tabProvider(for: uri)?.make(uri) else { return nil }
        page?.view.removeFromSuperview()
        mainArea?.view.removeFromSuperview()
        current = mainArea
        welcome?.removeFromSuperview()
        welcome = nil
        page = made
        card.pin(made.view)
        made.focus()
        return made
    }

    /// Evicts the areas past the newest `keep`, except those with unsaved files. Those stay listed, and go on a later
    /// switch once saved, because an area dropped from the list would stay loaded, with its terminal attached, until
    /// shown again.
    static func evicting(_ recent: [String], keep: Int, edited: (String) -> Bool) -> (recent: [String], gone: [String])
    {
        let gone = recent.dropFirst(keep).filter { !edited($0) }
        return (recent.filter { !gone.contains($0) }, gone)
    }

    /// Adds a tab to the layout of a workspace that isn't on screen (`Workbench.layouts`), and the workspace's editor
    /// area follows it if loaded. A tab already open there is brought to the front of its pane. A tab that runs
    /// something starts only in a loaded area.
    func openInBackground(_ uri: String, workspace id: String) {
        guard !TabURI.runs(uri) else {
            areas[id]?.runURI(uri)
            return
        }
        // When the browser built-in is off, a web page opens outside Kelp, as `EditorArea.open` does.
        if TabURI.scheme(uri) != "session", app.extensions.tabProvider(for: uri) == nil, let url = URL(string: uri),
            url.scheme?.hasPrefix("http") == true
        {
            return PreviewLinks.openOutside(url)
        }
        var layout = app.workbench.layouts[id]
        if let tab = layout.pageTab(for: uri) ?? layout.tab(uri: uri) {
            layout.select(tab.id)
        } else if let tab = layout.fileTab(sameFileAs: uri, real: EditorArea.realPath) {
            layout.select(tab.id)
            // Show the file at the line asked for. A built tab moves there now, and a tab not built yet opens there.
            if let line = TabURI.filePath(uri).line {
                if let content = areas[id]?.contents[tab.id] {
                    content.goTo(line: line)
                } else if let gid = layout.group(of: tab.id),
                    let index = layout.groups[gid]?.tabs.firstIndex(where: { $0.id == tab.id })
                {
                    layout.groups[gid]?.tabs[index].uri = uri
                }
            }
        } else {
            _ = layout.add(uri, to: layout.focusedGroup?.id)
        }
        app.workbench.layouts[id] = layout
    }

    /// Called when chats left a workspace that may not be on screen. Their tabs leave its layout, and a group left with
    /// no tab closes a day later if nothing opens there (`WorkspaceActions.closeIdle`).
    func chatsLeft(_ id: String) {
        var layout = app.workbench.layouts[id]
        for tab in layout.allTabs
        where TabURI.scheme(tab.uri) == "session" && app.session(TabURI.body(tab.uri))?.worktreeId != id {
            layout.remove(tab.id)
        }
        app.workbench.layouts[id] = layout
        if layout.allTabs.isEmpty { WorkspaceActions(app).emptied(id) }
    }

    /// Closes a chat from its row, on any screen, with the questions its tab asks and with ⇧⌘T to reopen it. Where the
    /// tab is built, it closes. Otherwise the session ends and its tab leaves the workspace's layout.
    func closeChat(_ sid: String, workspace id: String) {
        let uri = TabURI.session(sid)
        if let area = areas[id], let tab = area.layout.tab(uri: uri) {
            area.closeTab(tab.id)
            return
        }
        let title = app.session(sid)?.displayTitle ?? ""
        Task {
            guard await app.extensions.tabProvider(for: uri)?.closeUnbuilt?(uri) ?? true else { return }
            var layout = app.workbench.layouts[id]
            guard let tab = layout.tab(uri: uri) else { return }
            areas[id]?.closed.insert(sid)   // if loaded meanwhile, the daemon's next update mustn't bring the tab back
            app.workbench.closedTabs.remember(
                ClosedTab(uri: uri, title: title, workspace: id, group: layout.group(of: tab.id), index: nil))
            layout.remove(tab.id)
            app.workbench.layouts[id] = layout
            if layout.allTabs.isEmpty { WorkspaceActions(app).emptied(id) }
        }
    }

    /// Puts a restarted session into its old tab in a workspace that isn't on screen, or into a tab of its own when
    /// there is no old tab.
    func replaceInBackground(_ old: String, with new: String, workspace id: String) {
        var layout = app.workbench.layouts[id]
        guard let tab = layout.replace(old, with: new) else { return openInBackground(new, workspace: id) }
        layout.select(tab.id)
        app.workbench.layouts[id] = layout
    }

    private func refresh() {
        for (id, area) in areas where app.worktree(id) == nil {
            area.view.removeFromSuperview()
            own.removeValue(forKey: id)?.close()
            areas[id] = nil
            app.workbench.layouts.forget(id)
            recent.removeAll { $0 == id }
            // When closed from elsewhere (the CLI, an agent), unsaved files still get their question, only without
            // Cancel.
            let edited = area.editedFiles
            guard !edited.isEmpty else {
                area.removeFromParent()
                continue
            }
            Task {
                let answer = await runSheet(UnsavedChanges.alert(edited, quitting: false, canCancel: false))
                if await UnsavedChanges.settle(edited, answer, canCancel: false) {
                    _ = await UnsavedChanges.written(edited)
                }
                area.removeFromParent()
            }
        }
        if let shown = mainArea, areas[shown.workspaceId] == nil { mainArea = nil }
        if let shown = current, areas[shown.workspaceId] == nil {
            current = mainArea
            app.workbench.mainWindowBecameKey()   // the group with the keys is gone, so the main window has them
        }
        // Only the areas on screen reconcile now. The others reconcile when shown.
        ([mainArea] + own.keys.map { areas[$0] }).forEach { $0?.reconcile() }
        if mainArea == nil, page == nil { showWelcome() }
    }

    private func showWelcome() {
        let hasRepos = app.repos.contains { !NoProject.holds($0) }
        if let shown = welcome as? WelcomeView, shown.hasRepos == hasRepos { return }
        welcome?.removeFromSuperview()
        let fresh = WelcomeView(hasRepos: hasRepos, app: app)
        card.pin(fresh)
        welcome = fresh
    }
}

/// The view shown when no workspace is selected. On the first run it is the welcome (the only one, with no sheet over
/// it), and otherwise it says where to pick a workspace.
@MainActor
final class WelcomeView: NSView {
    let hasRepos: Bool
    init(hasRepos: Bool, app: AppModel) {
        self.hasRepos = hasRepos
        super.init(frame: .zero)
        let icon = NSImageView(image: .symbol(hasRepos ? "sidebar.left" : "bubble.left"))
        icon.symbolConfiguration = .chrome(Metrics.iconHero)
        icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(
            labelWithString: hasRepos ? String(localized: "Select a Chat") : String(localized: "Welcome to Kelp"))
        // New Chat's key as it stands. Without one, the button below is what to press.
        let new = app.extensions.keyText("workspace.new") ?? String(localized: "New Chat")
        let body = NSTextField(
            wrappingLabelWithString: hasRepos
                ? String(localized: "Pick a chat in the sidebar, or press \(new) for a new one.")
                : String(
                    localized:
                        "Ask an agent anything right away, or add a project folder: agents, terminals and files side by side."
                ))
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        // A chat needs no project, so with no project yet a chat is the first thing to do and adding a project the
        // second.
        let chat = ClosureButton(title: String(localized: "New Chat")) { [app] in app.workbench.newChat() }
        let add = ClosureButton(title: String(localized: "Add Project…")) { [app] in app.workbench.addProject() }
        // The words grow with Text size, which this very screen offers, as soon as it is picked.
        track(owner: self) { [app] in
            app.themes.chromeText
        } changed: { _ in
            title.font = .ui(TextSize.title, weight: .semibold)
            body.font = .ui(TextSize.body)
        }
        let buttons = NSStackView(views: hasRepos ? [chat] : [add, chat])
        for case let button as NSButton in buttons.arrangedSubviews {
            button.bezelStyle = .push
            button.controlSize = .large
        }
        chat.keyEquivalent = "\r"
        // On the first run, the look and the agent a new chat starts are picked here before anything else (the same
        // tiles as in Settings).
        let setup = hasRepos ? nil : NSHostingView(rootView: WelcomeSetup().environment(app))
        let stack = NSStackView(views: [icon, title, body] + (setup.map { [$0] } ?? []) + [buttons])
        stack.orientation = .vertical
        stack.spacing = Metrics.gapWide
        stack.setCustomSpacing(Metrics.sheetInset, after: setup ?? body)
        if setup != nil { stack.setCustomSpacing(2 * Metrics.inset, after: body) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Metrics.emptyLift),
            body.widthAnchor.constraint(equalToConstant: Metrics.sheetWidth - 2 * Metrics.sheetInset)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
