import AppKit
import Core
import DesignKit
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
    /// What is shown of this session, kept with the panel's and the Map tab's choices alike (`WorkChoices`): the turn
    /// (an index into `work.turns`, nil for the last), or the whole session, and one agent's touches or all.
    let choices: WorkChoices
    var turn: Int? {
        get { choices[session].turn }
        set { choices[session].turn = newValue }
    }
    var whole: Bool {
        get { choices[session].whole }
        set { choices[session].whole = newValue }
    }
    /// Only this agent's touches (an index into `work.agents`), or nil for all.
    var agent: Int? {
        get { choices[session].agent }
        set { choices[session].agent = newValue }
    }
    private(set) var work: AgentWork?
    private(set) var error: String?
    private(set) var loaded = false
    private var reading: Task<Void, Never>?

    init(app: AppModel, choices: WorkChoices) {
        self.app = app
        self.choices = choices
    }

    /// Shows another session, with what was chosen for it before.
    func show(_ id: String?) {
        guard id != session else { return }
        session = id
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
            received(value ?? nil, error: error)
        }
    }

    /// Takes an answer of `session.work`: a failed read keeps what was shown.
    func received(_ value: AgentWork?, error: String? = nil) {
        if let value { work = value }
        self.error = error
        loaded = true
    }

    /// The agents' names, by their index in the work: the catalog's for a session's agents, the kind for a subagent.
    var agentNames: [String] {
        (work?.agents ?? []).map { $0.role == .subagent ? $0.name : app.catalog.name($0.agent) }
    }

    /// Each agent's mark, by its index in the work: the catalog's logo for a session's agent, the subagent symbol for a
    /// subagent (its parent's logo would make the two look like one).
    func icons(size: CGFloat) -> [NSImage?] {
        (work?.agents ?? []).map { WorkModel.icon($0, app: app, size: size) }
    }

    static func icon(_ agent: AgentWork.Agent, app: AppModel?, size: CGFloat) -> NSImage? {
        agent.role == .subagent ? subagentMark(size) : app?.catalog.icon(agent.agent, size: size)
    }

    /// The subagents' mark, in the secondary label's colour, so it reads on light and dark alike when drawn by hand.
    static func subagentMark(_ size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: Metrics.iconWeight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        return NSImage.symbol("person.crop.square").withSymbolConfiguration(config)
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

    /// Opens a place outside the project where Kelp can: a site in its browser, an MCP server in Skills & MCP, a folder
    /// on this Mac in Finder. A host has nowhere to go from here.
    func open(outside place: AgentWork.Place) {
        switch place.kind {
        case .web:
            guard !place.name.contains(" ") else { return }
            let local = place.name.hasPrefix("127.0.0.1") || place.name.hasPrefix("localhost")
            app.workbench.open((local ? "http://" : "https://") + place.name)
        case .tool: app.workbench.showPanel("addons")
        case .outside, .own:
            // A host's folder isn't on this Mac: its work's root is the host's path, not the workspace's folder here.
            let workspace = session.flatMap(app.session)?.worktreeId.flatMap { id in app.worktrees.first { $0.id == id }
            }
            guard let root = work?.root, root == workspace?.path else { return }
            let path = place.name.hasPrefix("~") ? NSHomeDirectory() + place.name.dropFirst() : place.name
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        default: break
        }
    }
}

/// What is chosen for each session's work (the turn or the whole session, one agent), one choice per session for the
/// Work panel and the Map tab alike, so the two always show the same.
@MainActor
@Observable
final class WorkChoices {
    struct Choice: Equatable {
        var turn: Int?
        var whole = false
        var agent: Int?
    }
    private var bySession: [String: Choice] = [:]

    subscript(session: String?) -> Choice {
        get { session.flatMap { bySession[$0] } ?? Choice() }
        set { if let session { bySession[session] = newValue } }
    }
}

// How the app keeps what the daemon pushes about agents' work. This event kind belongs to the Work built-in.
extension WorkEvent: Pushed {
    package var key: String { session }
    package static var forgottenWith: WatchTopic? { .work }
}
