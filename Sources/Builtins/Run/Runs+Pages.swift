// Runs a tab doesn't show, and the pages runs serve: open, copy, a busy port.
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

extension Runs {
    // MARK: hidden runs

    /// Runs whose tab was put away in the Run menu: they keep running, the menu shows them (`run.hidden` in UIState, so a
    /// restarted Kelp doesn't bring their tabs back). The sidebar and the tabs leave them out (`Workbench.isHidden`).
    var hidden: Set<String> { state.hidden.union(app.uiState.strings("run.hidden")) }
    /// A run's tab can go into the Run menu: the run keeps going, the menu brings its output back.
    func tabItems(_ menu: NSMenu, _ session: Session) {
        guard choice(of: session) != nil else { return }
        menu.add(String(localized: "Hide in Run Menu")) { [weak self] in self?.hide(session.id) }
    }
    func hide(_ sid: String) {
        state.hidden.insert(sid)
        let live = app.uiState.strings("run.hidden").filter { app.session($0).map { $0.status != .exited } ?? false }
        app.uiState["run.hidden"] = .array((live.filter { $0 != sid } + [sid]).map(JSONValue.string))
        app.workbench.hideTab(uri: TabURI.session(sid))
    }
    /// Its tab again, below what you're doing, and the keys in it.
    func show(_ sid: String) {
        state.hidden.remove(sid)
        app.uiState["run.hidden"] = .array(app.uiState.strings("run.hidden").filter { $0 != sid }.map(JSONValue.string))
        app.workbench.open(TabURI.session(sid), split: .down, workspace: app.session(sid)?.worktreeId, focus: true)
    }

    /// How a run's tab stands out among terminals: its purpose's symbol in colour (green ▶ for a server) and a glow of
    /// that colour, the port it serves after its name. nil for any other session.
    func look(_ session: Session) -> (icon: NSImage?, glow: NSColor?)? {
        guard let wid = session.worktreeId, let picked = choice(of: session),
            var row = rows(wid).first(where: { $0.id == picked })
        else {
            return nil
        }
        row.running = false   // its purpose's mark, not the menu's "running" circle
        let (symbol, color) = Self.glyph(row)
        return (Self.tinted(symbol, color), color == .secondaryLabelColor ? nil : color)
    }

    /// What the workspace serves, its main page first: the title bar's capsule, ⇧⌘O and the sidebar's card.
    func pages(_ wid: String) -> [ServedPage] {
        ServedPages.list(
            printed: running(in: wid).compactMap { state.active[$0]?.url },
            ports: app.latest(PortsEvent.self, wid)?.ports ?? [])
    }

    /// The port after a tab's name: what its run printed, else what its session listens on.
    func port(of session: Session) -> Int? {
        state.active[session.id]?.url.flatMap { URLComponents(string: $0)?.port }
            ?? session.worktreeId.flatMap { app.latest(PortsEvent.self, $0)?.ports }?
            .first { $0.session == session.id && ServedPages.listed($0) }.map { $0.here ?? $0.port }
    }

    /// The page as this Mac reaches it, the ports read again when that moved it; nil and a banner when it can't be.
    func reach(_ page: ServedPage, in wid: String) async -> ServedPage? {
        let here = await page.reached(in: wid) { await app.call($0) }
        if here != page { app.watchAgain(.ports, wid) }
        return here
    }

    /// A page beside what you're doing, or the tab that shows it; what isn't one (a database) gets its address copied.
    func open(_ page: ServedPage, in wid: String) {
        Task {
            guard let page = await reach(page, in: wid) else { return }
            guard page.isWeb else {
                copy(page)
                return
            }
            app.workbench.open(page.url, split: .right, workspace: wid, focus: false)
        }
    }

    func copy(_ page: ServedPage) {
        copyText(page.address)
        Banner.show(String(localized: "Copied \(page.address)"))
    }

    /// A run that couldn't start: who holds its port, when that's one of Kelp's own screens on this Mac.
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

    /// ⇧⌘O: the main page of the workspace on screen.
    func openPage() {
        guard let wid = app.workbench.workspaceId, let page = pages(wid).first else {
            NSSound.beep()
            return
        }
        open(page, in: wid)
    }
}
