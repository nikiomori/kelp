import Agents
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// Opening, selecting, cycling, splitting and closing tabs.
extension EditorArea {
    // MARK: tabs

    /// `focus: false` shows the tab but leaves the keys where they are (a click in the Files tree).
    func select(_ tab: String, focus: Bool = true) {
        let old = layout.focused
        layout.select(tab)
        if let old, old != layout.focused { refreshGroup(old) }
        if let gid = layout.group(of: tab) { refreshGroup(gid) }
        if focus { focusSelected() }
        publishFocus()
        scheduleSave()
    }

    /// A `terminal:` or `agent:` URI: what it says is run. Kelp's own callers only (`ArchitectureTests`), never a URL that came
    /// from elsewhere: those go through `open`, which only shows things.
    func runURI(_ uri: String, split: SplitDirection? = nil, focus: Bool = true) {
        let components = URLComponents(string: uri)
        func value(_ name: String) -> String? { components?.queryItems?.first { $0.name == name }?.value }
        if TabURI.scheme(uri) == "agent" {
            newAgent(
                components?.path.isEmpty == false ? components?.path : nil, prompt: value("prompt"), split: split,
                focus: focus)
        } else if let name = value("tmux") {
            newTmux(name, split: split, focus: focus)
        } else {
            run(command: value("cmd"), title: value("title"), split: split, focus: focus)
        }
    }

    /// A path as the disk has it (/tmp/x is /private/tmp/x), so one file has one tab however it was reached; what isn't
    /// there (yet) as given.
    static func realPath(_ path: String) -> String { Paths.real(path) ?? path }

    /// Opens a URI in the focused group (or a new group to the right / below). Reuses a tab already showing it. Only shows:
    /// callers hand it links from a forge or a tracker, and one saying `terminal:?cmd=…` starts nothing.
    func open(_ uri: String, split: SplitDirection? = nil, focus: Bool = true) {
        guard !TabURI.runs(uri) else { return }
        // A page already open stays where it is, even when asked for beside you: a second click must not move it.
        if let tab = layout.pageTab(for: uri) {
            select(tab.id, focus: focus)
            return
        }
        // A file already open (at another line, or by another path to it): that tab, moved to the line asked for.
        if layout.tab(uri: uri) == nil, let tab = layout.fileTab(sameFileAs: uri, real: Self.realPath) {
            select(tab.id, focus: focus)
            if let line = TabURI.filePath(uri).line { contents[tab.id]?.goTo(line: line) }
            return
        }
        if let tab = layout.tab(uri: uri) {   // already open (maybe added by reconcile a moment ago)
            if let split, let gid = layout.group(of: tab.id) {
                layout.split(tab.id, from: gid, vertical: split == .right, before: false)
                arrange()
                render()
            }
            select(tab.id, focus: focus)
            return
        }
        if TabURI.scheme(uri) != "session", app.extensions.tabProvider(for: uri) == nil {
            if let url = URL(string: uri), url.scheme?.hasPrefix("http") == true {
                PreviewLinks.openOutside(url)
                return
            }   // browser extension off
        }
        var target: String? = layout.focusedGroup?.id
        if let split, let focused = target {
            target = layout.newGroup(beside: focused, vertical: split == .right)
            zoomed = nil
        }
        let tab = layout.add(uri, to: target)
        arrange()
        render()
        select(tab.id, focus: focus)
    }

    /// What an agent or a script asks to show (`kelp open` without `--focus`): the pane you're in stays yours, its keys
    /// too. Only a tab that lands on top of what you were looking at takes them, with nothing else left to type in.
    func showAside(_ uri: String, split: SplitDirection? = nil) {
        let typing = (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
        let yours = layout.focusedGroup?.selectedTab?.id
        open(uri, split: split, focus: false)
        if let yours, let gid = layout.group(of: yours), layout.groups[gid]?.selected == yours, gid != layout.focused {
            let shown = layout.focused
            layout.focused = gid
            shown.map(refreshGroup)
            refreshGroup(gid)
            publishFocus()
        }
        if typing { focusSelected() }   // a new pane rebuilds the area, which takes the keys from the terminal
    }

    func closeTab(_ id: String, remember: Bool = true) { Task { await closeTabAsking(id, remember: remember) } }

    /// Closes the tab once it agrees (its questions are sheets, awaited); false when it stays. `remember`: ⇧⌘T can bring it
    /// back, unless Kelp itself took it away (a finished commit's tab, a run started over).
    @discardableResult
    func closeTabAsking(_ id: String, remember: Bool = true) async -> Bool {
        guard closing.insert(id).inserted else { return false }
        defer { closing.remove(id) }
        let uri = layout.allTabs.first { $0.id == id }?.uri ?? ""
        let sid = TabURI.scheme(uri) == "session" ? TabURI.body(uri) : nil
        // A tab not built yet (in the background since launch) closes all the same: an agent's ends its session.
        if let content = contents[id] {
            guard await content.close() else { return false }
        } else if let close = app.extensions.tabProvider(for: uri)?.closeUnbuilt, await !close(uri) {
            return false
        }
        guard layout.allTabs.contains(where: { $0.id == id }) else { return true }   // gone while it asked (its workspace closed)
        if remember { rememberClosing(id) }
        drop(id, session: sid)
        if layout.allTabs.isEmpty { WorkspaceActions(app).closeEmpty(workspaceId, ended: sid) }
        return true
    }

    /// The tab leaves the layout; what it showed isn't asked (closing asked already, hiding keeps it running). A session's
    /// tab doesn't come back with the daemon's next update.
    func drop(_ id: String, session sid: String? = nil) {
        let sid =
            sid
            ?? layout.allTabs.first { $0.id == id }.flatMap {
                TabURI.scheme($0.uri) == "session" ? TabURI.body($0.uri) : nil
            }
        if let sid { closed.insert(sid) }
        contents[id] = nil
        layout.remove(id)
        if layout.allTabs.isEmpty {
            let manual = layout.manual
            layout = WorkspaceLayout()
            layout.manual = manual
        }
        arrange()
        render()
        focusSelected()
    }

    /// Sessions being looked at, which a finished agent's second on screen counts for (`Glances`).
    var attendedSessions: [String] {
        layout.attendedTabs(zoomed: zoomed).map(\.uri).filter { TabURI.scheme($0) == "session" }.map(TabURI.body)
    }

    package var focusedContent: TabContent? { layout.focusedGroup?.selectedTab.flatMap { contents[$0.id] } }

    func closeFocusedTab() { if let tab = layout.focusedGroup?.selectedTab { closeTab(tab.id) } }

    func selectTab(index: Int) {
        guard let group = layout.focusedGroup, group.tabs.indices.contains(index) else { return }
        select(group.tabs[index].id)
    }
    func cycleTab(_ offset: Int) { if let id = layout.tab(cycling: offset) { select(id) } }
    /// ⇧⌘↩: the focused group fills the editor area, or every pane comes back (like zooming a split in Terminal or Ghostty).
    func toggleZoom() {
        guard let group = layout.focusedGroup, (layout.root?.sessions.count ?? 0) > 1 else {
            NSSound.beep()
            return
        }
        zoomed = zoomed == nil ? group.id : nil
        render()
        focusSelected()
    }

    func focusGroup(_ offset: Int) {
        zoomed = nil
        if let id = layout.tabInGroup(cycling: offset) { select(id) }
    }
    /// ⌥⌘ arrows: the pane on that side of the focused one, the nearest by center (Ghostty's goto_split).
    func focusGroup(toward edge: NSRectEdge) {
        guard let cur = layout.focusedGroup?.id, let from = groupViews[cur], from.window != nil else { return }
        var others: [String: CGRect] = [:]
        for (id, pane) in groupViews where id != cur && pane.window != nil {
            others[id] = pane.convert(pane.bounds, to: nil)
        }
        guard
            let gid = WorkspaceLayout.nearestPane(
                from: from.convert(from.bounds, to: nil), among: others, toward: edge),
            let tab = layout.groups[gid]?.selectedTab
        else {
            NSSound.beep()
            return
        }
        select(tab.id)
    }

    /// Moves the focused tab into a new group to the right / below.
    package func splitFocused(_ dir: SplitDirection) {
        zoomed = nil
        arrangedByHand()
        guard let group = layout.focusedGroup, let tab = group.selectedTab else { return }
        if group.tabs.count == 1 {
            newTerminal(split: dir)
            return
        }   // nothing to move: open a terminal there, like a terminal app
        layout.split(tab.id, from: group.id, vertical: dir == .right, before: false)
        render()
        focusSelected()
    }

    /// Agents side by side, the default: each running agent in a pane of its own; terminals, commands, files and paused
    /// or ended agents share one more (a paused agent shown would wake). Done as tabs come and go; true if panes moved.
    @discardableResult
    func arrange() -> Bool {
        guard layout.manual != true else { return false }
        let agents = layout.allTabs.filter { tab in
            guard TabURI.scheme(tab.uri) == "session", let session = app.session(TabURI.body(tab.uri)) else {
                return false
            }
            return session.isAgent && session.status != .exited && session.status != .paused
        }
        let old = layout
        layout.tile(agents.map(\.id))
        return layout != old
    }

    /// The title bar's button and ⌃⌘T: agents side by side, or every tab back in one pane, arranged by hand from then on.
    package func toggleSideBySide() {
        zoomed = nil
        layout.manual = layout.manual == true ? nil : true
        if layout.manual == true { layout.tile([]) } else { arrange() }
        render()
        focusSelected()
        publishFocus()
    }

    /// A split or a tab dragged to another pane: the panes stay as the user puts them, agents no longer tile.
    func arrangedByHand() {
        guard layout.manual != true else { return }
        layout.manual = true
        publishFocus()
    }

    func tabMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        if let uri = layout.allTabs.first(where: { $0.id == id })?.uri,
            let items = app.extensions.tabProvider(for: uri)?.menu
        {
            items(menu, uri, workspaceId) { [weak self] in self?.open($0, split: .right) }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
        }
        menu.add(String(localized: "Split Right")) { [weak self] in
            self?.select(id)
            self?.splitFocused(.right)
        }
        menu.add(String(localized: "Split Down")) { [weak self] in
            self?.select(id)
            self?.splitFocused(.down)
        }
        menu.addItem(.separator())
        // A run's tab can go into the Run menu: the run keeps going, the menu brings its output back.
        if let uri = layout.allTabs.first(where: { $0.id == id })?.uri, TabURI.scheme(uri) == "session",
            let session = app.session(TabURI.body(uri)), session.status != .exited
        {
            app.extensions.all.runs?.tabMenu(menu, session)
        }
        menu.add(String(localized: "Close Tab")) { [weak self] in self?.closeTab(id) }
        let tabs = layout.group(of: id).flatMap { layout.groups[$0]?.tabs } ?? []
        func close(_ title: String, _ gone: [TabRef]) {
            guard !gone.isEmpty else { return }
            menu.add(title) { [weak self] in Task { for tab in gone { await self?.closeTabAsking(tab.id) } } }   // one question at a time
        }
        close(String(localized: "Close Other Tabs"), tabs.filter { $0.id != id })
        close(String(localized: "Close Tabs to the Right"), Array(tabs.drop { $0.id != id }.dropFirst()))
        menu.addItem(.separator())
        menu.addChoiceMenu(SettingKeys.tabWidth, app, title: String(localized: "Tab Width"))
        menu.addChoiceMenu(SettingKeys.tabHeight, app, title: String(localized: "Tab Height"))
        return menu
    }

    /// "+" menu, in the empty workspace's order (`NewTabChoices`): the agents, what opens, what runs, then Make.
    func newTabMenu(group: String?) -> NSMenu {
        let app = self.app
        let focus: @MainActor () -> Void = { [weak self] in if let group { self?.layout.focused = group } }
        let menu = NSMenu()
        let agents = NewTabChoices.agents(app), def = app.catalog.defaultAgent
        menu.addItem(.sectionHeader(title: String(localized: "Agents")))
        let notes = app.extensions.all.plans?.notes() ?? [:]
        let shown = agents.prefix(NewTabChoices.shown), rest = agents.dropFirst(NewTabChoices.shown)
        func agentItem(_ agent: AgentManifest, in menu: NSMenu, column: CGFloat) {
            let item = menu.add(agent.name) { [weak self] in
                focus()
                self?.newAgent(agent.id)
            }
            item.show(app.catalog.icon(agent.id))
            if let note = notes[agent.id] {
                item.attributedTitle = NSMenuItem.titleWithNote(
                    agent.name, note: note.text, column: column, noteColor: note.color)
            }
            if agent.id == def, let shortcut = NewTabChoices.defaultKey(app) {
                item.keyEquivalent = shortcut.key
                item.keyEquivalentModifierMask = shortcut.mods.flags
            }
        }
        let column = NSMenuItem.noteColumn(shown.map(\.name))
        for agent in shown { agentItem(agent, in: menu, column: column) }
        if agents.isEmpty {
            menu.addItem(withTitle: String(localized: "No agent CLIs found"), action: nil, keyEquivalent: "")
                .isEnabled =
                false
        }
        if !rest.isEmpty {
            let sub = NSMenu(), column = NSMenuItem.noteColumn(rest.map(\.name))
            for agent in rest { agentItem(agent, in: sub, column: column) }
            let item = menu.addItem(withTitle: String(localized: "Other Agents"), action: nil, keyEquivalent: "")
            item.show(.symbol("ellipsis.circle"))
            item.submenu = sub
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Open")))
        let open = NewTabChoices.open(app, app.worktree(workspaceId)) { [weak self] in self?.newTerminal() }
        for choice in open { menu.add(choice, before: focus) }
        let run = app.extensions.all.runs?.choices(workspaceId) ?? []
        if !run.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: String(localized: "Run")))
            for choice in run { menu.add(choice) }
        }
        if !agents.isEmpty {
            menu.addItem(.separator())
            let sub = NSMenu()
            Make.addItems(to: sub, heading: false) { [weak self] line in
                focus()
                self?.newAgent(prompt: line, draft: true)
            }
            let item = menu.addItem(withTitle: String(localized: "Make"), action: nil, keyEquivalent: "")
            item.show(.symbol("doc.text"))
            item.submenu = sub
        }
        return menu
    }

}
