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
    /// The editor area (or the welcome) is in this card, under the window bar, which lies over this view's top.
    private let card = Card()
    private var areas: [String: EditorArea] = [:]
    private var recent: [String] = []
    private(set) var current: EditorArea?
    /// A workspace's editor area while it's loaded (shown lately), on screen or not.
    func area(_ id: String) -> EditorArea? { areas[id] }
    var editedFiles: [SavableTab] { areas.values.flatMap(\.editedFiles) }
    func editedFiles(in ids: [String]) -> [SavableTab] { ids.compactMap { areas[$0] }.flatMap(\.editedFiles) }
    private var welcome: NSView?
    private static let keep = 4

    override func loadView() {
        let app = self.app
        view = NSView()
        view.pin(card, inset: NSEdgeInsets(top: WindowBar.height, left: Card.gap, bottom: Card.gap, right: Card.gap))
        card.identifier = Banner.anchor   // banners sit in its corner
        showWelcome()
        // Daemon state: workspaces that are gone leave; sessions' tabs come and show their status and context ring.
        track {
            app.repos
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track {
            app.worktrees
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track {
            app.sessions
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track {
            app.latest(ContextEvent.self).byKey
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track {
            app.themes.look
        } changed: { [weak self] in
            self?.card.look = $0
        }
    }

    func show(_ id: String?) {
        if let previous = page {   // back from a page: it goes (it reads its server only while it's there)
            previous.view.removeFromSuperview()
            page = nil
            if let shown = current, shown.workspaceId == id {
                card.pin(shown.view)
                shown.focusSelected()
                return
            }
        }
        if let shown = current, shown.workspaceId == id { return }
        current?.view.removeFromSuperview()
        guard let id, app.worktree(id) != nil else {
            current = nil
            showWelcome()
            return
        }
        welcome?.removeFromSuperview()
        welcome = nil
        let area = areas[id] ?? EditorArea(app: app, workspaceId: id)
        if areas[id] == nil {
            areas[id] = area
            addChild(area)
        }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        // Their terminals detach.
        let gone: [String]
        (recent, gone) = Self.evicting(recent, keep: Self.keep) { self.areas[$0]?.editedFiles.isEmpty == false }
        for old in gone {
            areas[old]?.removeFromParent()
            areas[old] = nil
        }
        current = area
        card.pin(area.view)
        area.reconcile()
        area.focusSelected()
    }

    /// What `showPage` shows in place of the workspace's area, which stays loaded behind it.
    private var page: TabContent?

    /// A page made by its extension's tab provider, filling the card; nil when none makes it.
    func showPage(_ uri: String) -> TabContent? {
        guard let made = app.extensions.tabProvider(for: uri)?.make(uri) else { return nil }
        page?.view.removeFromSuperview()
        current?.view.removeFromSuperview()
        welcome?.removeFromSuperview()
        welcome = nil
        page = made
        card.pin(made.view)
        made.focus()
        return made
    }

    /// The areas past the newest `keep` go, except those with unsaved files: they stay listed, and go on a later switch
    /// once saved (dropped from the list, one would stay loaded, and its terminal attached, until shown again).
    static func evicting(_ recent: [String], keep: Int, edited: (String) -> Bool) -> (recent: [String], gone: [String])
    {
        let gone = recent.dropFirst(keep).filter { !edited($0) }
        return (recent.filter { !gone.contains($0) }, gone)
    }

    /// A tab for a workspace that isn't on screen, into its layout (`Workbench.layouts`), which its editor area follows
    /// if it's loaded: one already open there is brought to the front of its pane. What runs starts only in a loaded one.
    func openInBackground(_ uri: String, workspace id: String) {
        guard !TabURI.runs(uri) else {
            areas[id]?.runURI(uri)
            return
        }
        var layout = app.workbench.layouts[id]
        if let tab = layout.pageTab(for: uri) ?? layout.tab(uri: uri)
            ?? layout.fileTab(sameFileAs: uri, real: EditorArea.realPath)
        {
            layout.select(tab.id)
        } else {
            _ = layout.add(uri, to: layout.focusedGroup?.id)
        }
        app.workbench.layouts[id] = layout
    }

    /// Chats went from a workspace that may not be on screen: their tabs leave its layout, and a group left with no tab
    /// closes.
    func chatsLeft(_ id: String) {
        var layout = app.workbench.layouts[id]
        for tab in layout.allTabs
        where TabURI.scheme(tab.uri) == "session" && app.session(TabURI.body(tab.uri))?.worktreeId != id {
            layout.remove(tab.id)
        }
        app.workbench.layouts[id] = layout
        if layout.allTabs.isEmpty { WorkspaceActions(app).closeEmpty(id, ended: nil) }
    }

    /// A chat closed from its row, on any screen, with the questions its tab asks and ⇧⌘T after: its tab closing where
    /// it's built, else its session ending and its tab leaving the workspace's layout.
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
            areas[id]?.closed.insert(sid)   // loaded meanwhile: the daemon's next update mustn't bring the tab back
            app.workbench.closedTabs.remember(
                ClosedTab(uri: uri, title: title, workspace: id, group: layout.group(of: tab.id), index: nil))
            layout.remove(tab.id)
            app.workbench.layouts[id] = layout
            if layout.allTabs.isEmpty { WorkspaceActions(app).closeEmpty(id, ended: sid) }
        }
    }

    /// A restarted session into its old tab in a workspace that isn't on screen; with no old tab, a tab of its own.
    func replaceInBackground(_ old: String, with new: String, workspace id: String) {
        var layout = app.workbench.layouts[id]
        guard let tab = layout.replace(old, with: new) else { return openInBackground(new, workspace: id) }
        layout.select(tab.id)
        app.workbench.layouts[id] = layout
    }

    private func refresh() {
        for (id, area) in areas where app.worktree(id) == nil {
            area.view.removeFromSuperview()
            areas[id] = nil
            app.workbench.layouts.forget(id)
            recent.removeAll { $0 == id }
            // Closed from elsewhere (the CLI, an agent): unsaved files still get their question, only without Cancel.
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
        if let shown = current, areas[shown.workspaceId] == nil { current = nil }
        current?.reconcile()   // the others reconcile when shown
        if current == nil, page == nil { showWelcome() }
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

/// No workspace selected: the first run's welcome (the only one: no sheet over it), else where to pick one.
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
            labelWithString: hasRepos ? String(localized: "Select a chat") : String(localized: "Welcome to Kelp"))
        title.font = .ui(20, weight: .semibold)
        let body = NSTextField(
            wrappingLabelWithString: hasRepos
                ? String(localized: "Pick a chat in the sidebar, or press ⌘N for a new one.")
                : String(
                    localized:
                        "Ask an agent anything right away, or add a project folder: agents, terminals and files side by side."
                ))
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        // With no project yet a chat needs none: it's the first thing to do, adding a project the second.
        let chat = ClosureButton(title: String(localized: "New Chat")) { [app] in app.workbench.newChat() }
        let add = ClosureButton(title: String(localized: "Add Project…")) { [app] in app.workbench.addProject() }
        let buttons = NSStackView(views: hasRepos ? [chat] : [add, chat])
        for case let button as NSButton in buttons.arrangedSubviews {
            button.bezelStyle = .push
            button.controlSize = .large
        }
        chat.keyEquivalent = "\r"
        // First run: how it looks and who answers, picked here before anything else (the same tiles as in Settings).
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
