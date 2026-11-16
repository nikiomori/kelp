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
        let rel = (root.isEmpty ? nil : Paths.relative(path, to: root)) ?? path
        let suffix = lines.map { $0.count == 1 ? ":\($0.lowerBound)" : ":\($0.lowerBound)-\($0.upperBound)" } ?? ""
        return ShellQuote.escapedPath(rel) + suffix
    }

    /// The agents text for "the agent" may go to in a workspace (the one on screen when nil): running, an agent (not a
    /// terminal, whose shell would run the text's lines, nor a plain command), and not a reviewer (`SessionRole`), which
    /// reports on others' work rather than changing it.
    package func agents(in workspace: String? = nil) -> [Session] {
        let wid = workspace ?? app.workbench.workspaceId
        return app.sessions.filter {
            $0.worktreeId == wid && $0.status != .exited && $0.isAgent && $0.role != .reviewer
        }
    }

    /// The one of them it goes to without asking: the one the user was last with, else the only one. Nil when there's
    /// none, or several and the user was with none of them.
    package func agent(in workspace: String? = nil) -> Session? {
        let live = agents(in: workspace)
        if let last = app.workbench.lastSession, let session = live.first(where: { $0.id == last }) { return session }
        return live.count == 1 ? live[0] : nil
    }

    /// `agent(in:)`, else asked which of several: findings sent to the wrong one would have it change code it didn't
    /// write. Nil when there's none or the user picked none.
    package func pickAgent(in workspace: String? = nil) async -> Session? {
        if let sure = agent(in: workspace) { return sure }
        let live = agents(in: workspace)
        guard live.count > 1 else { return nil }
        let id = await pick(
            String(localized: "Send to which agent?"),
            from: live.map { ("\($0.displayTitle) [\($0.id.prefix(6))]", $0.id) },
            action: String(localized: "Send"), width: 240)
        return id.flatMap { id in live.first { $0.id == id } }
    }

    /// Types the reference into the agent's prompt without pressing Return, and shows the agent.
    package func sendToAgent(_ path: String, lines: ClosedRange<Int>? = nil) {
        sendToAgent(text: reference(path, lines: lines))
    }

    /// Words into the agent's prompt, not sent: the user adds what to do with them.
    package func sendToAgent(text: String) {
        guard !agents().isEmpty else {
            Banner.show(
                String(localized: "No agent on this screen. Start one with ⌥⌘T, then send again."), style: .error)
            return
        }
        Task {
            guard let agent = await pickAgent() else { return }
            await app.call(SessionSend(id: agent.id, text: text + " ", enter: false))
            app.workbench.focus(session: agent.id)
        }
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
        guard !FileActions(app).agents(in: wid).isEmpty else {
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
        Task {
            guard let agent = await FileActions(app).pickAgent(in: wid) else { return }
            if await type(recipe, worktree: wid, vars: vars, into: agent.id) { app.workbench.focus(session: agent.id) }
        }
    }

    /// The recipe typed into the session, not sent: other people's text (errors, CI logs, review comments) waits for Return.
    func type(_ recipe: String, worktree wid: String, vars: [String: String], into sid: String) async -> Bool {
        guard let text = await app.call(RecipeRender(id: wid, name: recipe, vars: vars)) else { return false }
        await app.call(SessionSend(id: sid, text: text, enter: false))
        return true
    }
}
