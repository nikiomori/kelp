import Agents
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// Session-level agent actions shared by tabs and the sidebar.
@MainActor
package struct AgentActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    func rename(_ sid: String) {
        let cur = app.session(sid)?.title ?? ""
        Task {
            guard
                let title = await prompt(
                    String(localized: "Rename"),
                    String(localized: "Leave empty to name it from the task automatically."),
                    initial: cur)
            else { return }
            await app.call(SessionRename(id: sid, title: title))
        }
    }

    /// Runs the same command again in the same tab, and resumes the conversation when the agent supports it.
    package func restart(_ sid: String) {
        Task {
            guard app.restarting.insert(sid).inserted else { return }   // ignores a second click while it restarts
            defer { app.restarting.remove(sid) }   // the old session's tab is kept for the new one
            guard let session = await app.call(SessionRestart(id: sid)) else { return }
            app.sessions.removeAll { $0.id == sid }
            app.upsert(session)
            app.workbench.replace(session: sid, with: session.id, workspace: session.worktreeId)
        }
    }

    package func stop(_ ids: [String]) {
        let one = ids.count == 1
        let question = one ? String(localized: "Stop this agent?") : String(localized: "Stop \(ids.count) agents?")
        let detail =
            (one ? String(localized: "Its session ends") : String(localized: "Their sessions end"))
            + ". " + String(localized: "Conversations can be resumed from Session History.")
            + app.sessions.childrenWords(of: ids)
        // The button says what it stops, and it is red because the action is destructive.
        let action = one ? String(localized: "Stop Agent") : String(localized: "Stop \(ids.count) Agents")
        Task {
            guard await confirm(question, detail: detail, action: action, destructive: true) else { return }
            for id in ids { await app.call(SessionKill(id: id)) }
        }
    }

    /// Adds the items a session's row offers wherever it shows outside its project's list (Activity). With `lastTurn`
    /// it builds the menu of the session's tab instead, which has the changes of its last turn after Copy Context,
    /// Restart last, and no Stop.
    package func addSessionItems(to menu: NSMenu, _ sid: String, lastTurn: (@MainActor () -> Void)? = nil) {
        menu.add(String(localized: "Rename…")) { rename(sid) }
        if app.session(sid)?.isTerminal != true {   // a terminal has no conversation to copy or hand over
            menu.add(String(localized: "Hand Off to"), submenu: handoffMenu(sid))
            addFork(to: menu, sid)
            addMove(to: menu, sid)
            menu.add(String(localized: "Copy Context")) { copyContext(sid) }
            if let lastTurn { menu.add(String(localized: "Changes in Its Last Turn"), lastTurn) }
            if lastTurn != nil, AgentFollow.can(app, sid) {
                menu.add(String(localized: "Follow Edits")) { AgentFollow.of(app).toggle(sid) }.state =
                    AgentFollow.of(app).follows(sid) ? .on : .off
            }
        }
        guard lastTurn == nil else {
            menu.add(String(localized: "Restart")) { restart(sid) }
            return
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Restart")) { restart(sid) }
        menu.add(String(localized: "Stop…")) { stop([sid]) }
    }

    /// Builds the "Hand Off to ▸ Codex" menu. A new agent in the same workspace gets what this one did (its
    /// conversation, or the terminal's text) as a brief typed into its prompt but not sent. ⌥ hands over the full
    /// transcript instead of the latest part.
    func handoffMenu(_ sid: String) -> NSMenu {
        let menu = NSMenu()
        for a in app.catalog.installed {
            menu.add(a.name) { handoff(sid, to: a.id, full: false) }.show(app.catalog.icon(a.id))
            let full = menu.add(String(localized: "\(a.name) — Full Transcript")) { handoff(sid, to: a.id, full: true) }
            full.isAlternate = true
            full.keyEquivalentModifierMask = .option
            full.show(app.catalog.icon(a.id))
        }
        return menu
    }

    /// Hands the session's work to `agent`. With `send`, the brief is sent straight away because nobody needs to read
    /// it first (an agent out of plan handing its work over).
    package func handoff(_ sid: String, to agent: String, full: Bool, send: Bool = false) {
        open(
            SessionHandoff(
                id: sid, agent: agent, full: full,
                prompt: "Continue the task where the previous agent left off: check what's done, then finish it.",
                draft: !send), split: .right)
    }

    /// Starts the chat `method` makes and opens its tab in its workspace.
    private func open<M: RPCMethod>(_ method: M, split: SplitDirection? = nil) where M.Result == Session {
        Task {
            guard let session = await app.call(method) else { return }
            app.upsert(session)
            app.workbench.open(TabURI.session(session.id), split: split, workspace: session.worktreeId)
        }
    }

    /// Adds "Fork Chat" for an agent that can fork. It opens a new chat beside this one that goes on from a copy of its
    /// conversation.
    func addFork(to menu: NSMenu, _ sid: String) {
        guard canFork(sid) else { return }
        menu.add(String(localized: "Fork Chat")) { fork(sid) }
    }
    /// Whether the chat's agent can fork. The menu's item and the File menu's command are both offered by it.
    func canFork(_ sid: String) -> Bool { app.catalog.manifest(app.session(sid)?.agent)?.forks == true }

    /// Adds "Continue On ▸ box". The chat goes on in a copy of its project on another machine (a server, or this Mac),
    /// in a branch worktree there with its commits and uncommitted changes, briefed as Hand Off does. The chat here
    /// pauses. The copies are the projects with the same name, and the daemon checks they share their first commit.
    func addMove(to m: NSMenu, _ sid: String) {
        guard let worktree = app.worktree(app.session(sid)?.worktreeId), let mine = app.repo(worktree.repoId) else {
            return
        }
        let copies = app.repos.filter { $0.id != mine.id && $0.name == mine.name }
        guard !copies.isEmpty else { return }
        let menu = NSMenu()
        for repo in copies {
            let place = RemoteHost.of(repo.path)?.host ?? String(localized: "This Mac")
            menu.add(place) { move(sid, to: repo.id, place: place) }
        }
        m.add(String(localized: "Continue On"), submenu: menu)
    }

    func move(_ sid: String, to repoId: String, place: String) {
        Banner.show(String(localized: "Moving the chat to \(place)…"))
        open(SessionMoveAcross(id: sid, repoId: repoId))
    }

    func fork(_ sid: String) { open(SessionFork(id: sid), split: .right) }

    /// Marks a chat unread by hand, so its row asks for a look again.
    func markUnread(_ sid: String) { Task { await app.call(SessionMarkUnread(id: sid)) } }

    func copyContext(_ sid: String) {
        Task {
            guard let context = await app.call(SessionContext(id: sid)) else { return }
            copyText(context)
            Banner.show(String(localized: "Context copied"))
        }
    }
}
