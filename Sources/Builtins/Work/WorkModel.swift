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
    /// The picker's choice (`AgentPicker.Entry.key`), nil for all.
    var picked: String? {
        get { choices[session].agents }
        set { choices[session].agents = newValue }
    }
    /// Only these agents' touches (indices into `work.agents`), or nil for all.
    var agents: Set<Int>? {
        guard let picked, let work else { return nil }
        return AgentPicker.entries(work, names: agentNames).first { $0.key == picked }?.members
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

    /// The project's folder on this Mac: the session's workspace (a remote one's local folder, not the host's path),
    /// else the work's root.
    var localRoot: String? {
        session.flatMap(app.session)?.worktreeId.flatMap { id in app.worktrees.first { $0.id == id }?.path }
            ?? work?.root
    }

    /// Where a project file is on this Mac: under the worktree it was touched in, when it was.
    func path(of place: AgentWork.Place) -> String? {
        guard let root = localRoot else { return nil }
        let base = place.worktree.map { root + "/.claude/worktrees/" + $0 } ?? root
        return place.name == "." ? base : base + "/" + place.name
    }

    /// Whether a file's diff can be shown: a turn's, not the whole session's.
    var showsDiff: Bool { !whole }

    /// Opens a project file beside the agent; with the Option key, the turn's diff of it.
    func open(_ place: AgentWork.Place, diff: Bool) {
        guard let session = session.flatMap(app.session), let workspace = session.worktreeId else { return }
        let file = path(of: place)
        guard diff, showsDiff, let work else {
            return _ = file.map { app.workbench.openBeside(TabURI.file($0), in: workspace) }
        }
        guard let turn, work.turns.indices.contains(turn), turn < work.turns.count - 1 else {
            if let uri = diffURI(place, mark: nil) { return app.workbench.open(uri) }
            return _ = file.map { app.workbench.openBeside(TabURI.file($0), in: workspace) }
        }
        // An earlier turn's: the snapshot Kelp took when it began names it to the diff tab.
        let start = work.turns[turn].at, end = work.turns[turn + 1].at, id = session.id
        Task { [app] in
            let marks = await app.quiet(SessionTurns(id: id)) ?? []
            // The oldest in the turn's window, as the daemon takes it for the turn's command changes.
            let mark = marks.last { $0.at >= start.addingTimeInterval(-5) && $0.at < end }
            // No snapshot of that turn: the file as it is.
            guard let mark, let uri = self.diffURI(place, mark: mark) else {
                return _ = file.map { app.workbench.openBeside(TabURI.file($0), in: workspace) }
            }
            app.workbench.open(uri)
        }
    }

    /// The diff tab for a file's changes in the turn shown: the last turn's (`mark` nil) or the turn `mark` began, its
    /// agent named; a file edited in a worktree of the project, that worktree's changes, if Kelp knows it.
    func diffURI(_ place: AgentWork.Place, mark: SessionTurns.Mark?) -> String? {
        guard let id = session, let workspace = app.session(id)?.worktreeId else { return nil }
        if let name = place.worktree {
            let base = localRoot.map { $0 + "/.claude/worktrees/" + name }
            guard let tree = app.worktrees.first(where: { $0.path == base }) else { return nil }
            return TabURI.diff(tree.id, file: place.name)
        }
        return TabURI.diff(workspace, file: place.name, source: .turn, session: id, turn: mark?.id)
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
            let first = step.detail.components(separatedBy: ", ").first,
            let place = work.places.first(where: { $0.kind == .file && $0.name == first })
        {
            return open(place, diff: NSEvent.modifierFlags.contains(.option))
        }
        app.workbench.focus(session: id)
    }

    /// Whether `open(outside:)` has somewhere to take a place: a host or a web search has none.
    func opens(_ place: AgentWork.Place) -> Bool {
        switch place.kind {
        case .web: !place.name.contains(" ")
        case .tool: true
        case .outside, .own:
            work?.root
                == session.flatMap(app.session)?.worktreeId.flatMap { id in app.worktrees.first { $0.id == id } }?.path
        default: false
        }
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
        /// The agents picked, by `AgentPicker.Entry.key`: one agent, or all subagents of one kind. Not an index, so a
        /// subagent that appears later doesn't shift the pick.
        var agents: String?
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
