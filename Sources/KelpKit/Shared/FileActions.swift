// A file handed to an agent or copied as a link, and a failed git step handed to an agent to fix.
import AppKit
import Core
import DesignKit

/// A file (or lines in it) handed to an agent or copied as a link.
@MainActor
package struct FileActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    /// "Sources/App.swift:12-30": workspace-relative, the way agents read a reference.
    func reference(_ path: String, lines: ClosedRange<Int>?) -> String {
        let root = app.worktree(app.workbench.workspaceId)?.path ?? ""
        let rel = !root.isEmpty && path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let suffix = lines.map { $0.count == 1 ? ":\($0.lowerBound)" : ":\($0.lowerBound)-\($0.upperBound)" } ?? ""
        return ShellQuote.escapedPath(rel) + suffix
    }

    /// The agent the user was last with in this workspace (never a plain terminal).
    package var targetAgent: Session? {
        let model = app, wid = app.workbench.workspaceId
        if let session = app.workbench.lastSession.flatMap(model.session), session.agent != "shell",
            session.worktreeId == wid,
            session.status != .exited
        {
            return session
        }
        return model.sessions.last { $0.worktreeId == wid && $0.isChat && $0.status != .exited }
    }

    /// Types the reference into the agent's prompt without pressing Return, and shows the agent.
    package func sendToAgent(_ path: String, lines: ClosedRange<Int>? = nil) {
        guard let agent = targetAgent else {
            Banner.show(
                String(localized: "No agent on this screen. Start one with ⌥⌘T, then send again."), style: .error)
            return
        }
        Task { await app.call(SessionSend(id: agent.id, text: reference(path, lines: lines) + " ", enter: false)) }
        app.workbench.focus(session: agent.id)
    }

    /// Words into the agent's prompt, not sent: the user adds what to do with them.
    package func sendToAgent(text: String) {
        guard let agent = targetAgent else {
            Banner.show(
                String(localized: "No agent on this screen. Start one with ⌥⌘T, then send again."), style: .error)
            return
        }
        Task { await app.call(SessionSend(id: agent.id, text: text + " ", enter: false)) }
        app.workbench.focus(session: agent.id)
    }

    package func copyReference(_ path: String, lines: ClosedRange<Int>?) {
        copyText(reference(path, lines: lines))
    }
}

/// A git step that failed for a reason an agent can fix (hooks, a rejected push, conflicts): the error banner
/// offers to hand it to the workspace's agent, with the error, as a prompt waiting for Return.
@MainActor
package struct GitFix {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    package func offer(_ error: String, recipe: String, worktree wid: String, vars: [String: String] = [:]) {
        guard FileActions(app).targetAgent != nil else {
            Banner.show(error, style: .error)
            return
        }
        Banner.show(
            error, style: .error,
            action: (
                String(localized: "Ask Agent to Fix"),
                {
                    send(recipe, worktree: wid, vars: vars.merging(["error": error]) { a, _ in a })
                }
            ))
    }

    package func send(_ recipe: String, worktree wid: String, vars: [String: String]) {
        guard let agent = FileActions(app).targetAgent else { return }
        Task {
            if await type(recipe, worktree: wid, vars: vars, into: agent.id) { app.workbench.focus(session: agent.id) }
        }
    }

    /// The recipe typed into the session, not sent: other people's text (errors, CI logs, review comments) waits for Return.
    package func type(_ recipe: String, worktree wid: String, vars: [String: String], into sid: String) async -> Bool {
        guard let text = await app.call(RecipeRender(id: wid, name: recipe, vars: vars)) else { return false }
        await app.call(SessionSend(id: sid, text: text, enter: false))
        return true
    }
}
