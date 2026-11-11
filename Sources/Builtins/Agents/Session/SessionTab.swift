import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// An agent or terminal session as a tab (libghostty via PaneView; the daemon keeps the process).
@MainActor
final class SessionTab: TabContent {
    let sessionId: String
    let app: AppModel
    let pane: PaneView
    var uri: String { TabURI.session(sessionId) }
    var view: NSView { pane }

    init?(uri: String, app: AppModel) {
        let sid = TabURI.body(uri)
        guard let session = app.session(sid) else { return nil }
        sessionId = sid
        self.app = app
        pane = PaneView(session: session, app: app)
        pane.onRestart = { p in AgentActions(app).restart(p.sessionId) }
        pane.onClose = { p in app.workbench.closeTab(uri: TabURI.session(p.sessionId)) }
        // A terminal left with `exit` (code 0) while its tab is open closes, as Terminal's does; an agent, a failed
        // command or a tab opened onto an ended session keeps its output and the Restart / Close bar.
        var running = session.status != .exited
        track(owner: self) { [app] in
            app.session(sid)
        } changed: { [weak self] session in
            guard let self, let session else { return }
            pane.update(session)
            if running, session.status == .exited, session.agent == "shell", session.exitCode == 0 {
                app.workbench.closeTab(uri: uri)
            }
            running = session.status != .exited
        }
    }

    private var session: Session? { app.session(sessionId) }
    var title: String {
        session.map(app.catalog.displayName) ?? String(localized: "Session")
    }
    var icon: NSImage? { app.catalog.icon(session?.agent) }
    var badge: TabBadge? { .of(session, meter: app.latest(ContextEvent.self, sessionId)?.shown) }
    /// Only one on screen: a hidden pane's grid is from whatever size it last had.
    var terminalGrid: (cols: Int, rows: Int)? { pane.window == nil ? nil : pane.gridSize }
    var toolTip: String? {
        session.map {
            "\(title) — \($0.statusWords)" + ($0.summary.isEmpty ? "" : "\n\($0.summary)")
                + ($0.workingElsewhere.map { "\n\($0)" } ?? "")
                + ($0.backgroundTip.map { "\n\($0)" } ?? "")
        }
    }
    func focus() { pane.focus() }

    /// Closing the tab ends the session; it asks only when something would stop: a working agent, what a finished one
    /// left running, or a program running in a terminal (an idle shell or a finished agent with nothing left just closes).
    func close() async -> Bool { await Self.close(app, session: sessionId) }

    /// Its items in the tab's context menu.
    static func menu(
        _ app: AppModel, _ m: NSMenu, uri: String, workspace: String, openBeside: @escaping @MainActor (String) -> Void
    ) {
        let sid = TabURI.body(uri)
        AgentActions(app).addSessionItems(to: m, sid) {
            app.workbench.lastSession = sid
            openBeside(TabURI.diff(workspace, source: "turn"))
        }
    }

    /// Also for a tab that was never built (EditorArea closes those without making them).
    static func close(_ app: AppModel, session sid: String) async -> Bool {
        let session = app.session(sid)
        let beside = session?.aside ?? [], names = beside.joined(separator: ", ")
        if let session, session.agent != "shell",
            session.status == .working || !beside.isEmpty || !app.sessions.childrenWords(of: [sid]).isEmpty
        {
            let detail =
                (session.status == .working
                    ? String(localized: "The agent is still working. Closing the tab ends its session.")
                    : String(localized: "Closing the tab ends its session.")) + app.sessions.childrenWords(of: [sid])
                + (beside.isEmpty ? "" : " " + String(localized: "What it runs in the background stops too: \(names)."))
            guard
                await confirm(
                    String(localized: "Stop \(app.catalog.displayName(session))?"), detail: detail,
                    action: String(localized: "Stop Agent"))
            else { return false }
        } else if session?.agent == "shell", let program = await busy(app, sid) {
            guard
                await confirm(
                    String(localized: "Stop “\(program)”?"),
                    detail: String(localized: "It is still running in this terminal. Closing the tab stops it."),
                    action: String(localized: "Stop and Close"))
            else { return false }
        }
        Task { await app.call(SessionKill(id: sid)) }
        return true
    }

    /// What runs in the foreground of a terminal: the tab closes or stays on this answer. A daemon that doesn't answer
    /// within 2 s closes the tab as if nothing ran.
    private static func busy(_ app: AppModel, _ sid: String) async -> String? {
        await app.quiet(SessionBusy(id: sid), timeout: 2) ?? nil
    }
}
