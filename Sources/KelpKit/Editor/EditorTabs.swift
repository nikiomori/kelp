import AppKit
import Agents
import Core
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
        publishFocus(); scheduleSave()
    }

    /// A `terminal:` or `agent:` URI: what it says is run. Kelp's own callers only (`ArchitectureTests`), never a URL that came
    /// from elsewhere: those go through `open`, which only shows things.
    func runURI(_ uri: String, split: SplitDirection? = nil, focus: Bool = true) {
        let q = URLComponents(string: uri)
        func value(_ name: String) -> String? { q?.queryItems?.first { $0.name == name }?.value }
        if TabURI.scheme(uri) == "agent" { newAgent(q?.path.isEmpty == false ? q?.path : nil, prompt: value("prompt"), split: split, focus: focus) }
        else if let name = value("tmux") { newTmux(name, split: split, focus: focus) }
        else { run(command: value("cmd"), title: value("title"), split: split, focus: focus) }
    }

    /// Opens a URI in the focused group (or a new group to the right / below). Reuses a tab already showing it. Only shows:
    /// callers hand it links from a forge or a tracker, and one saying `terminal:?cmd=…` starts nothing.
    func open(_ uri: String, split: SplitDirection? = nil, focus: Bool = true) {
        guard !TabURI.runs(uri) else { return }
        // A page already open stays where it is, even when asked for beside you: a second click must not move it.
        if let t = layout.pageTab(for: uri) { select(t.id, focus: focus); return }
        // A file already open (at another line): that tab, moved to the line asked for.
        if layout.tab(uri: uri) == nil, let t = layout.fileTab(sameFileAs: uri) {
            select(t.id, focus: focus)
            if let l = TabURI.filePath(uri).line { contents[t.id]?.goTo(line: l) }
            return
        }
        if let t = layout.tab(uri: uri) {   // already open (maybe added by reconcile a moment ago)
            if let split, let gid = layout.group(of: t.id) {
                layout.split(t.id, from: gid, vertical: split == .right, before: false)
                arrange()
                render()
            }
            select(t.id, focus: focus); return
        }
        if TabURI.scheme(uri) != "session", app.extensions.tabProvider(for: uri) == nil {
            if let u = URL(string: uri), u.scheme?.hasPrefix("http") == true { PreviewLinks.openOutside(u); return }   // browser extension off
        }
        var target: String? = layout.focusedGroup?.id
        if let split, let f = target { target = layout.newGroup(beside: f, vertical: split == .right); zoomed = nil }
        let t = layout.add(uri, to: target)
        arrange(); render()
        select(t.id, focus: focus)
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
            shown.map(refreshGroup); refreshGroup(gid)
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
        if let c = contents[id] {
            guard await c.close() else { return false }
        } else if let close = app.extensions.tabProvider(for: uri)?.closeUnbuilt, await !close(uri) { return false }
        guard layout.allTabs.contains(where: { $0.id == id }) else { return true }   // gone while it asked (its workspace closed)
        if remember { rememberClosing(id) }
        drop(id, session: sid)
        if layout.allTabs.isEmpty { WorkspaceActions(app).closeEmpty(workspaceId, ended: sid) }
        return true
    }

    /// The tab leaves the layout; what it showed isn't asked (closing asked already, hiding keeps it running). A session's
    /// tab doesn't come back with the daemon's next update.
    func drop(_ id: String, session sid: String? = nil) {
        let sid = sid ?? layout.allTabs.first { $0.id == id }.flatMap { TabURI.scheme($0.uri) == "session" ? TabURI.body($0.uri) : nil }
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

    func closeFocusedTab() { if let t = layout.focusedGroup?.selectedTab { closeTab(t.id) } }

    func selectTab(index: Int) {
        guard let g = layout.focusedGroup, g.tabs.indices.contains(index) else { return }
        select(g.tabs[index].id)
    }
    func cycleTab(_ offset: Int) { if let id = layout.tab(cycling: offset) { select(id) } }
    /// ⇧⌘↩: the focused group fills the editor area, or every pane comes back (like zooming a split in Terminal or Ghostty).
    func toggleZoom() {
        guard let g = layout.focusedGroup, (layout.root?.sessions.count ?? 0) > 1 else { NSSound.beep(); return }
        zoomed = zoomed == nil ? g.id : nil
        render(); focusSelected()
    }

    func focusGroup(_ offset: Int) {
        zoomed = nil
        if let id = layout.tabInGroup(cycling: offset) { select(id) }
    }
    /// ⌥⌘ arrows: the pane on that side of the focused one, the nearest by center (Ghostty's goto_split).
    func focusGroup(toward edge: NSRectEdge) {
        guard let cur = layout.focusedGroup?.id, let from = groupViews[cur], from.window != nil else { return }
        var others: [String: CGRect] = [:]
        for (id, v) in groupViews where id != cur && v.window != nil { others[id] = v.convert(v.bounds, to: nil) }
        guard let gid = WorkspaceLayout.nearestPane(from: from.convert(from.bounds, to: nil), among: others, toward: edge),
              let t = layout.groups[gid]?.selectedTab else { NSSound.beep(); return }
        select(t.id)
    }

    /// Moves the focused tab into a new group to the right / below.
    package func splitFocused(_ dir: SplitDirection) {
        zoomed = nil
        arrangedByHand()
        guard let g = layout.focusedGroup, let t = g.selectedTab else { return }
        if g.tabs.count == 1 { newTerminal(split: dir); return }   // nothing to move: open a terminal there, like a terminal app
        layout.split(t.id, from: g.id, vertical: dir == .right, before: false)
        render(); focusSelected()
    }

    /// Agents side by side, the default: each running agent in a pane of its own; terminals, commands, files and paused
    /// or ended agents share one more (a paused agent shown would wake). Done as tabs come and go; true if panes moved.
    @discardableResult
    func arrange() -> Bool {
        guard layout.manual != true else { return false }
        let agents = layout.allTabs.filter { t in
            guard TabURI.scheme(t.uri) == "session", let s = app.session(TabURI.body(t.uri)) else { return false }
            return s.isAgent && s.status != .exited && s.status != .paused
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
        layout.manual = true; publishFocus()
    }

    func tabMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        if let uri = layout.allTabs.first(where: { $0.id == id })?.uri, let items = app.extensions.tabProvider(for: uri)?.menu {
            items(m, uri, workspaceId) { [weak self] in self?.open($0, split: .right) }
            if !m.items.isEmpty { m.addItem(.separator()) }
        }
        m.add(String(localized: "Split Right")) { [weak self] in self?.select(id); self?.splitFocused(.right) }
        m.add(String(localized: "Split Down")) { [weak self] in self?.select(id); self?.splitFocused(.down) }
        m.addItem(.separator())
        // A run's tab can go into the Run menu: the run keeps going, the menu brings its output back.
        if let uri = layout.allTabs.first(where: { $0.id == id })?.uri, TabURI.scheme(uri) == "session",
           let s = app.session(TabURI.body(uri)), s.status != .exited, app.scripts.choice(of: s) != nil {
            m.add(String(localized: "Hide in Run Menu")) { [app] in app.scripts.hide(s.id) }
        }
        m.add(String(localized: "Close Tab")) { [weak self] in self?.closeTab(id) }
        let tabs = layout.group(of: id).flatMap { layout.groups[$0]?.tabs } ?? []
        func close(_ title: String, _ gone: [TabRef]) {
            guard !gone.isEmpty else { return }
            m.add(title) { [weak self] in Task { for t in gone { await self?.closeTabAsking(t.id) } } }   // one question at a time
        }
        close(String(localized: "Close Other Tabs"), tabs.filter { $0.id != id })
        close(String(localized: "Close Tabs to the Right"), Array(tabs.drop { $0.id != id }.dropFirst()))
        return m
    }

    /// "+" menu, in the empty workspace's order (`NewTabChoices`): the agents, what opens, what runs, then Make.
    func newTabMenu(group: String?) -> NSMenu {
        let app = self.app
        let focus: @MainActor () -> Void = { [weak self] in if let group { self?.layout.focused = group } }
        let m = NSMenu()
        let agents = NewTabChoices.agents(app), def = app.catalog.defaultAgent
        m.addItem(.sectionHeader(title: String(localized: "Agents")))
        let notes = app.planNotes
        let shown = agents.prefix(NewTabChoices.shown), rest = agents.dropFirst(NewTabChoices.shown)
        func agentItem(_ a: AgentManifest, in menu: NSMenu, column: CGFloat) {
            let item = menu.add(a.name) { [weak self] in focus(); self?.newAgent(a.id) }
            item.show(app.catalog.icon(a.id))
            if let n = notes[a.id] {
                item.attributedTitle = ScriptsMenu.title(a.name, note: n.text, column: column, noteColor: n.color)
            }
            if a.id == def, let k = NewTabChoices.defaultKey { item.keyEquivalent = k.key; item.keyEquivalentModifierMask = k.mods.flags }
        }
        let column = ScriptsMenu.column(shown.map(\.name))
        for a in shown { agentItem(a, in: m, column: column) }
        if agents.isEmpty { m.addItem(withTitle: String(localized: "No agent CLIs found"), action: nil, keyEquivalent: "").isEnabled = false }
        if !rest.isEmpty {
            let sub = NSMenu(), column = ScriptsMenu.column(rest.map(\.name))
            for a in rest { agentItem(a, in: sub, column: column) }
            let item = m.addItem(withTitle: String(localized: "Other Agents"), action: nil, keyEquivalent: "")
            item.show(.symbol("ellipsis.circle"))
            item.submenu = sub
        }
        m.addItem(.separator())
        m.addItem(.sectionHeader(title: String(localized: "Open")))
        let open = NewTabChoices.open(app, app.worktree(workspaceId)) { [weak self] in self?.newTerminal() }
        for a in open { m.add(a, before: focus) }
        let run = NewTabChoices.run(app, workspace: workspaceId)
        if !run.isEmpty {
            m.addItem(.separator())
            m.addItem(.sectionHeader(title: String(localized: "Run")))
            for a in run { m.add(a) }
        }
        if !agents.isEmpty {
            m.addItem(.separator())
            let sub = NSMenu()
            Make.addItems(to: sub, heading: false) { [weak self] line in focus(); self?.newAgent(prompt: line, draft: true) }
            let item = m.addItem(withTitle: String(localized: "Make"), action: nil, keyEquivalent: "")
            item.show(.symbol("doc.text"))
            item.submenu = sub
        }
        return m
    }

}
