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

    /// Same command in the same tab; resumes the conversation when the agent supports it.
    package func restart(_ sid: String) {
        Task {
            app.restarting.insert(sid)
            defer { app.restarting.remove(sid) }   // its tab is kept for the new one
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
        // The button says what it stops (destructive: red).
        let action = one ? String(localized: "Stop Agent") : String(localized: "Stop \(ids.count) Agents")
        Task {
            guard await confirm(question, detail: detail, action: action, destructive: true) else { return }
            for id in ids { await app.call(SessionKill(id: id)) }
        }
    }

    /// What a session's row offers wherever it shows outside its project's list (Activity); with `lastTurn`, its tab's
    /// menu: the changes of its last turn after Copy Context, Restart last and no Stop.
    package func addSessionItems(to m: NSMenu, _ sid: String, lastTurn: (@MainActor () -> Void)? = nil) {
        m.add(String(localized: "Rename…")) { rename(sid) }
        if app.session(sid)?.agent != "shell" {   // a terminal has no conversation to copy or hand over
            m.add(String(localized: "Hand Off to"), submenu: handoffMenu(sid))
            addFork(to: m, sid)
            addMove(to: m, sid)
            m.add(String(localized: "Copy Context")) { copyContext(sid) }
            if let lastTurn { m.add(String(localized: "Changes in Its Last Turn"), lastTurn) }
            if lastTurn != nil, AgentFollow.can(app, sid) {
                m.add(String(localized: "Follow Edits")) { AgentFollow.of(app).toggle(sid) }.state =
                    AgentFollow.of(app).follows(sid) ? .on : .off
            }
        }
        guard lastTurn == nil else {
            m.add(String(localized: "Restart")) { restart(sid) }
            return
        }
        m.addItem(.separator())
        m.add(String(localized: "Restart")) { restart(sid) }
        m.add(String(localized: "Stop…")) { stop([sid]) }
    }

    /// "Hand Off to ▸ Codex": a new agent in the same workspace gets what this one did (its conversation, or the
    /// terminal's text) as a brief typed into its prompt, not sent. ⌥ hands over the full transcript instead of the latest part.
    func handoffMenu(_ sid: String) -> NSMenu {
        let menu = NSMenu()
        for a in app.catalog.installed(app.catalog.all) {
            menu.add(a.name) { handoff(sid, to: a.id, full: false) }.image = app.catalog.icon(a.id)
            let full = menu.add(String(localized: "\(a.name) — Full Transcript")) { handoff(sid, to: a.id, full: true) }
            full.isAlternate = true
            full.keyEquivalentModifierMask = .option
            full.image = app.catalog.icon(a.id)
        }
        return menu
    }

    /// `send`: the brief goes straight in, nobody needs to read it first (an agent out of plan handing its work over).
    package func handoff(_ sid: String, to agent: String, full: Bool, send: Bool = false) {
        Task {
            let request = SessionHandoff(
                id: sid, agent: agent, full: full,
                prompt: "Continue the task where the previous agent left off: check what's done, then finish it.",
                draft: !send)
            guard let session = await app.call(request) else { return }
            app.upsert(session)
            app.workbench.open(TabURI.session(session.id), split: .right, workspace: session.worktreeId)
        }
    }

    /// "Fork Chat", for an agent that can: a new chat beside it going on from a copy of its conversation.
    func addFork(to m: NSMenu, _ sid: String) {
        guard app.catalog.manifest(app.session(sid)?.agent)?.forks == true else { return }
        m.add(String(localized: "Fork Chat")) { fork(sid) }
    }

    /// "Move to ▸ box": the chat goes on in its project's copy on another machine (a server, or this Mac), a branch
    /// worktree there with its commits and uncommitted changes, briefed as Hand Off does; the one here pauses. The
    /// copies are the projects of the same name; the daemon checks they share their first commit.
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
        m.add(String(localized: "Move to"), submenu: menu)
    }

    func move(_ sid: String, to repoId: String, place: String) {
        Banner.show(String(localized: "Moving the chat to \(place)…"))
        Task {
            guard let session = await app.call(SessionMoveAcross(id: sid, repoId: repoId)) else { return }
            app.upsert(session)
            app.workbench.open(TabURI.session(session.id), workspace: session.worktreeId)
        }
    }

    func fork(_ sid: String) {
        Task {
            guard let session = await app.call(SessionFork(id: sid)) else { return }
            app.upsert(session)
            app.workbench.open(TabURI.session(session.id), split: .right, workspace: session.worktreeId)
        }
    }

    func copyContext(_ sid: String) {
        Task {
            guard let context = await app.call(SessionContext(id: sid)) else { return }
            copyText(context)
            Banner.show(String(localized: "Context copied"))
        }
    }
}
