import AppKit
import Core
import WorkbenchKit
import KelpKit

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
        guard let s = app.session(sid) else { return nil }
        sessionId = sid; self.app = app
        pane = PaneView(session: s, app: app)
        pane.onRestart = { p in AgentActions(app).restart(p.sessionId) }
        pane.onClose = { p in app.workbench.closeTab(uri: TabURI.session(p.sessionId)) }
        track(owner: self) { [app] in app.session(sid) } changed: { [weak self] s in
            guard let self, let s else { return }
            pane.update(s)
        }
    }

    private var session: Session? { app.session(sessionId) }
    var title: String {
        session.map(app.catalog.displayName) ?? String(localized: "Session")
    }
    var icon: NSImage? { app.catalog.icon(session?.agent) }
    var badge: TabBadge? {
        let s = session
        // A terminal shows a state only while a program in it says how far it got (a build).
        return TabBadge(status: s.flatMap { $0.agent == "shell" ? ($0.progress == nil ? nil : .working) : $0.endedWithError ? .error : $0.markStatus },
                        unread: s?.unread ?? false, meter: app.contextUsage[sessionId],
                        progress: s?.progress.map { Double($0) / 100 }, attention: s.flatMap(Self.attention))
    }
    /// The ring around its pane: it asks (orange), failed (red), or finished and wasn't looked at yet (accent).
    private static func attention(_ s: Session) -> NSColor? {
        guard s.agent != "shell" else { return nil }
        if s.status == .waiting { return .systemOrange }
        if s.status == .error || s.endedWithError { return s.unread ? .systemRed : nil }
        return s.status == .done && s.unread ? .controlAccentColor : nil
    }
    /// Only one on screen: a hidden pane's grid is from whatever size it last had.
    var terminalGrid: (cols: Int, rows: Int)? { pane.window == nil ? nil : pane.gridSize }
    var toolTip: String? {
        session.map { "\(title) — \($0.statusWords)" + ($0.summary.isEmpty ? "" : "\n\($0.summary)") + ($0.workingElsewhere.map { "\n\($0)" } ?? "") }
    }
    func focus() { pane.focus() }

    /// Closing the tab ends the session; it asks only when something would stop: a working agent, or a program
    /// running in a terminal (an idle shell or a finished agent just closes).
    func close() async -> Bool { await Self.close(app, session: sessionId) }

    /// Its items in the tab's context menu.
    static func menu(_ app: AppModel, _ m: NSMenu, uri: String, workspace: String, openBeside: @escaping @MainActor (String) -> Void) {
        let sid = TabURI.body(uri)
        m.add(String(localized: "Rename…")) { AgentActions(app).rename(sid) }
        m.add(String(localized: "Restart")) { AgentActions(app).restart(sid) }
        m.add(String(localized: "Copy Context")) { AgentActions(app).copyContext(sid) }
        m.setSubmenu(AgentActions(app).handoffMenu(sid), for: m.addItem(withTitle: String(localized: "Hand Off to"), action: nil, keyEquivalent: ""))
        m.add(String(localized: "Changes in Its Last Turn")) {
            app.workbench.focusedSession = sid
            openBeside(TabURI.diff(workspace, source: "turn"))
        }
    }

    /// Also for a tab that was never built (EditorArea closes those without making them).
    static func close(_ app: AppModel, session sid: String) async -> Bool {
        let session = app.session(sid)
        if let s = session, s.agent != "shell", s.status == .working {
            let a = NSAlert(); a.messageText = String(localized: "Stop \(app.catalog.displayName(s))?")
            a.informativeText = String(localized: "The agent is still working. Closing the tab ends its session.")
            a.addButton(withTitle: String(localized: "Stop Agent")); a.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(a) == .alertFirstButtonReturn else { return false }
        } else if session?.agent == "shell", let program = await busy(app, sid) {
            let a = NSAlert()
            a.messageText = String(localized: "Stop “\(program)”?")
            a.informativeText = String(localized: "It is still running in this terminal. Closing the tab stops it.")
            a.addButton(withTitle: String(localized: "Stop and Close")); a.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(a) == .alertFirstButtonReturn else { return false }
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
