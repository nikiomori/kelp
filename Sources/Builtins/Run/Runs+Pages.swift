// Runs a tab doesn't show, and the pages runs serve: open, a busy port.
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

extension Runs {
    // MARK: hidden runs

    /// Runs whose tab was put away in the Run menu. They keep running and the menu shows them (`run.hidden` in
    /// UIState, so a restarted Kelp doesn't bring their tabs back). The sidebar and the tabs leave them out
    /// (`Workbench.isHidden`).
    var hidden: Set<String> { state.hidden.union(app.uiState.strings("run.hidden")) }
    /// Lets a run's tab go into the Run menu. The run keeps going, and the menu brings its output back.
    func tabItems(_ menu: NSMenu, _ session: Session) {
        guard choice(of: session) != nil else { return }
        menu.add(String(localized: "Hide in Run Menu")) { [weak self] in self?.hide(session.id) }
    }
    /// The run whose tab is in front; nil when the tab in front isn't a run's.
    var focusedRun: Session? {
        guard let uri = app.workbench.focusedContent?.uri, TabURI.scheme(uri) == "session",
            let session = app.session(TabURI.body(uri)), choice(of: session) != nil
        else { return nil }
        return session
    }
    func hide(_ sid: String) {
        state.hidden.insert(sid)
        let live = app.uiState.strings("run.hidden").filter { app.session($0).map { $0.status != .exited } ?? false }
        app.uiState["run.hidden"] = .array((live.filter { $0 != sid } + [sid]).map(JSONValue.string))
        app.workbench.hideTab(uri: TabURI.session(sid))
    }
    /// Shows the run's tab again, below what you're doing, with the keys in it.
    func show(_ sid: String) {
        state.hidden.remove(sid)
        app.uiState["run.hidden"] = .array(app.uiState.strings("run.hidden").filter { $0 != sid }.map(JSONValue.string))
        app.workbench.open(TabURI.session(sid), split: .down, workspace: app.session(sid)?.worktreeId, focus: true)
    }

    /// How a run's tab stands out among terminals: its purpose's symbol in grey (▶ for a server, a hammer for a
    /// build), and the port it serves after its name. No glow and no colour: a glow is for an agent calling you, and
    /// a purpose's colour lives in the Run menu while it runs. Nil for any other session.
    func look(_ session: Session) -> (icon: NSImage?, glow: NSColor?)? {
        guard let wid = session.worktreeId, let picked = choice(of: session),
            var row = rows(wid).first(where: { $0.id == picked })
        else {
            return nil
        }
        row.running = false   // shows its purpose's mark, not the menu's "running" circle
        return (Self.tinted(Self.glyph(row).0, .secondaryLabelColor), nil)
    }

    /// What the workspace serves, its main page first, for the title bar's capsule, ⇧⌘O and the sidebar's card.
    func pages(_ wid: String) -> [ServedPage] {
        ServedPages.list(
            printed: running(in: wid).compactMap { state.active[$0]?.url },
            ports: app.latest(PortsEvent.self, wid)?.ports ?? [])
    }

    /// The port shown after a tab's name: what its run printed, else what its session listens on.
    func port(of session: Session) -> Int? {
        state.active[session.id]?.url.flatMap { URLComponents(string: $0)?.port }
            ?? session.worktreeId.flatMap { app.latest(PortsEvent.self, $0)?.ports }?
            .first { $0.session == session.id && ServedPages.listed($0) }.map { $0.here ?? $0.port }
    }

    /// Opens a page beside what you're doing, or the tab that shows it. What isn't a page (a database) gets its
    /// address copied.
    func open(_ page: ServedPage, in wid: String) {
        let actions = PageActions(app)
        Task {
            guard page.isWeb else { return await actions.copy(page, in: wid) }
            guard let page = await actions.reach(page, in: wid) else { return }
            app.workbench.open(page.url, split: .right, workspace: wid, focus: false)
        }
    }

    /// For a run that couldn't start, says who holds its port, when that's one of Kelp's own screens on this Mac.
    func portBusy(_ event: PortBusyEvent) {
        Task {
            for worktree in app.worktrees where !worktree.archived && RemoteHost.of(worktree.path) == nil {
                guard
                    let port = await app.quiet(PortsList(worktreeId: worktree.id))?.first(where: {
                        $0.port == event.port && $0.session != event.session
                    })
                else { continue }
                let screen = app.groupName(worktree) ?? app.projectName(worktree.repoId) ?? worktree.displayName
                Banner.show(
                    String(localized: ":\(event.port) is taken: \(port.command) on \(screen)."),
                    action: (
                        String(localized: "Show"),
                        { [app] in
                            app.workbench.focus(session: port.session)
                        }
                    ))
                return
            }
        }
    }

    /// ⇧⌘O opens the main page of the workspace on screen.
    func openPage() {
        guard let front = frontPage else { return NSSound.beep() }
        open(front.page, in: front.workspace)
    }

    // MARK: the page capsule's right-click, for its page, and as commands for the page on screen

    /// The main page of the workspace on screen, the one the title bar's page capsule shows.
    var frontPage: (page: ServedPage, workspace: String)? {
        guard let wid = app.workbench.workspaceId, let page = pages(wid).first else { return nil }
        return (page, wid)
    }

    /// Opens the page in the default browser, outside Kelp.
    func openOutside(_ page: ServedPage, in wid: String) {
        Task {
            if let url = await PageActions(app).reach(page, in: wid).flatMap({ URL(string: $0.url) }) {
                PreviewLinks.openOutside(url)
            }
        }
    }

    func copyAddress(_ page: ServedPage, in wid: String) { Task { await PageActions(app).copy(page, in: wid) } }

    /// Whether the page is a host's port forwarded to this Mac, which Stop Forwarding takes back.
    func forwarded(_ page: ServedPage) -> Bool { page.host != nil && page.forwarded }

    func stopForwarding(_ page: ServedPage, in wid: String) {
        Task {
            if await app.call(PortsUnforward(worktreeId: wid, port: page.remotePort)) != nil {
                app.watchAgain(.ports, wid)
            }
        }
    }

    /// Stops the process that serves the page, when it runs on this Mac.
    func stopServer(_ page: ServedPage, in wid: String) {
        guard let pid = page.pid else { return NSSound.beep() }
        Task { await PageActions(app).stop(pid: pid, in: wid) }
    }
}
