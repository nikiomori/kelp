import AppKit
import Core
import KelpKit
import WorkbenchKit

/// One agent's work as the panel and the tab show it: which session, which turn (or the whole session), which agent's
/// touches, and the last answer of `session.work`. It is read again when the agent's conversations grow
/// (`WorkEvent`), only while someone looks.
@MainActor
@Observable
final class WorkModel {
    let app: AppModel
    private(set) var session: String?
    /// The turn shown (an index into `work.turns`), or nil for the last.
    var turn: Int?
    var whole = false
    /// Only this agent's touches (an index into `work.agents`), or nil for all.
    var agent: Int?
    private(set) var work: AgentWork?
    private(set) var error: String?
    private(set) var loaded = false
    private var reading: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    /// Shows another session: what was chosen for the last one doesn't carry over.
    func show(_ id: String?) {
        guard id != session else { return }
        session = id
        turn = nil
        whole = false
        agent = nil
        work = nil
        error = nil
        loaded = false
    }

    func load() {
        reading?.cancel()
        guard let session else { return }
        let ask = SessionWork(id: session, turn: turn, whole: whole ? true : nil)
        reading = Task { [weak self, app] in
            let (value, error) = await app.tryCall(ask)
            guard !Task.isCancelled, let self, self.session == session else { return }
            if let value { work = value }
            self.error = error
            loaded = true
        }
    }

    /// The agents' names, by their index in the work: the catalog's for a session's agents, the kind for a subagent.
    var agentNames: [String] {
        (work?.agents ?? []).map { $0.role == .subagent ? $0.name : app.catalog.name($0.agent) }
    }

    /// The project's folder name, for the top layer.
    var projectName: String {
        guard let root = work?.root else { return String(localized: "Project") }
        return (root as NSString).lastPathComponent
    }

    /// Where a project file is on this Mac: under the worktree it was touched in, when it was.
    func path(of place: AgentWork.Place) -> String? {
        guard let root = work?.root else { return nil }
        let base = place.worktree.map { root + "/.claude/worktrees/" + $0 } ?? root
        return place.name == "." ? base : base + "/" + place.name
    }

    /// Opens a project file beside the agent; with the Option key, the turn's diff of it.
    func open(_ place: AgentWork.Place, diff: Bool) {
        guard let session = session.flatMap(app.session), let workspace = session.worktreeId else { return }
        if diff {
            app.workbench.open(TabURI.diff(workspace, file: place.name, source: .turn))
        } else if let path = path(of: place) {
            _ = app.workbench.openBeside(TabURI.file(path), in: workspace)
        }
    }

    /// Opens what a step touched: its file, a subagent's journal, an agent it started, else the agent's terminal.
    func open(step: AgentWork.Step) {
        guard let id = session, let work else { return }
        let who = step.kind == .spawn ? step.other : step.agent
        if [.spawn, .report].contains(step.kind), let who, work.agents.indices.contains(who) {
            let agent = work.agents[who]
            switch agent.role {
            case .subagent: return agent.id.map { app.workbench.open(TabURI.subagent(session: id, id: $0)) } ?? ()
            case .child: return agent.id.map { app.workbench.focus(session: $0) } ?? ()
            case .main: break
            }
        }
        if [.read, .edit].contains(step.kind),
            let place = work.places.first(where: { $0.kind == .file && step.detail.hasPrefix($0.name) })
        {
            return open(place, diff: NSEvent.modifierFlags.contains(.option))
        }
        app.workbench.focus(session: id)
    }

    /// Opens a place outside the project where Kelp can: a site in its browser.
    func open(outside place: AgentWork.Place) {
        guard place.kind == .web, !place.name.contains(" ") else { return }
        let local = place.name.hasPrefix("127.0.0.1") || place.name.hasPrefix("localhost")
        app.workbench.open((local ? "http://" : "https://") + place.name)
    }
}

// How the app keeps what the daemon pushes about agents' work. This event kind belongs to the Work built-in.
extension WorkEvent: Pushed {
    package var key: String { session }
    package static var forgottenWith: WatchTopic? { .work }
}
