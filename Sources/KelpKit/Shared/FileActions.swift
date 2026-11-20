// A file handed to an agent or copied as a link, and a failed git step handed to an agent to fix.
import AppKit
import Core
import DesignKit

/// A file (or lines in it) handed to an agent or copied as a link.
@MainActor
package struct FileActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    /// Returns a reference such as "Sources/App.swift:12-30", relative to the workspace, the way agents read one.
    func reference(_ path: String, lines: ClosedRange<Int>?) -> String {
        let root = app.worktree(app.workbench.workspaceId)?.path ?? ""
        let rel = (root.isEmpty ? nil : Paths.relative(path, to: root)) ?? path
        let suffix = lines.map { $0.count == 1 ? ":\($0.lowerBound)" : ":\($0.lowerBound)-\($0.upperBound)" } ?? ""
        return ShellQuote.escapedPath(rel) + suffix
    }

    /// Returns the sessions in a workspace (the one on screen when nil) that text for "the agent" may go to. Each one
    /// is running and is an agent, not a terminal (whose shell would run the text's lines) or a plain command. It is
    /// also not a reviewer (`SessionRole`), because a reviewer reports on others' work rather than changing it.
    package func agents(in workspace: String? = nil) -> [Session] {
        let wid = workspace ?? app.workbench.workspaceId
        return app.sessions.filter {
            $0.worktreeId == wid && $0.status != .exited && $0.isAgent && $0.role != .reviewer
        }
    }

    /// Returns the agent that text goes to without asking: the one the user was last with, else the only one. It is
    /// nil when there's none, or when there are several and the user was last with none of them.
    package func agent(in workspace: String? = nil) -> Session? {
        let live = agents(in: workspace)
        if let last = app.workbench.lastSession, let session = live.first(where: { $0.id == last }) { return session }
        return live.count == 1 ? live[0] : nil
    }

    /// Returns `agent(in:)`, or else asks the user which of several agents to use, because findings sent to the wrong
    /// agent would have it change code it didn't write. Returns nil when there's none or the user picked none.
    package func pickAgent(in workspace: String? = nil) async -> Session? {
        if let sure = agent(in: workspace) { return sure }
        let live = agents(in: workspace)
        guard live.count > 1 else { return nil }
        let titles = Self.distinct(live.map(\.displayTitle))
        let id = await pick(
            String(localized: "Send to which agent?"), from: Array(zip(titles, live.map(\.id))),
            action: String(localized: "Send"))
        return id.flatMap { id in live.first { $0.id == id } }
    }

    /// The agents' names as the sidebar shows them, with a number after a name that comes again ("Claude", "Claude 2"),
    /// so two alike can be told apart without showing their ids.
    static func distinct(_ titles: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return titles.map { title in
            seen[title, default: 0] += 1
            return seen[title] == 1 ? title : "\(title) \(seen[title] ?? 0)"
        }
    }

    /// Types the reference into the agent's prompt without pressing Return, and shows the agent.
    package func sendToAgent(_ path: String, lines: ClosedRange<Int>? = nil) {
        sendToAgent(text: reference(path, lines: lines))
    }

    /// Types words into the agent's prompt without sending them, so the user adds what to do with them.
    package func sendToAgent(text: String) {
        guard !agents().isEmpty else {
            let new = NewTabChoices.defaultKey(app).map(KeyBindings.display) ?? String(localized: "New Agent")
            Banner.show(
                String(localized: "No agent on this screen. Start one with \(new), then send again."), style: .error)
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

/// Handles a git step that failed for a reason an agent can fix (hooks, a rejected push, conflicts). The error banner
/// offers to hand the step to the workspace's agent, with the error, as a prompt waiting for Return.
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

    /// Types the recipe into the session without sending it, because other people's text (errors, CI logs, review
    /// comments) should wait for Return.
    func type(_ recipe: String, worktree wid: String, vars: [String: String], into sid: String) async -> Bool {
        guard let text = await app.call(RecipeRender(id: wid, name: recipe, vars: vars)) else { return false }
        await app.call(SessionSend(id: sid, text: text, enter: false))
        return true
    }
}
