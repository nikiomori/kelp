import Core
import Foundation
import GRDB

/// What an agent's program may do with a method, as its handler says once (`Answered.agents`, beside its `fence`).
/// Anything else is the user's (commits, pushes, PRs, CI, trackers, credentials, projects, scripts, the daemon itself):
/// a method that says nothing is closed to agents.
enum AgentAccess {
    /// The user's alone.
    case none
    /// Only reads: a workspace it names may be any (a review of another branch, a status).
    case reads
    /// Acts: every session and workspace it names, whatever the field, is held to the agent's own
    /// (`Store.named(by:)`, `Store.workspaces(namedBy:)`), and each still has its own rules (`actsOn`, `inWorkspace`, …).
    case acts
}

/// What an agent's program may reach: the methods it may call (`methods`, beside the daemon's table of them), and the
/// rules every call is held to (`allow`, which `Daemon.allow` asks for every call).
enum AgentRules {
    /// What `caller` may reach with this call (`Daemon.allow`, which every path asks).
    /// A report comes from inside a session for that session only, by its process tree. A program an agent runs, or runs in
    /// a terminal it started (`parent`, `startedBy`, `origin`: all the daemon's, from the caller's process), reads, types
    /// into, stops and answers for only the sessions that agent started: any session a call names, in any of its fields,
    /// counts, so a method needn't remember to say so. A program the daemon started (an extension's, a git hook), one gone
    /// before it was looked at and one Kelp can't tell for the user's (`Caller.detached`) are held to the same with no
    /// session of their own; one under an agent the user typed into a terminal (`Caller.typedAgent`) as that terminal's
    /// agent; one whose own session's record is gone (a restart's old one) as an agent in no session (`forAnAgent`).
    /// The user's own terminals, and programs under an app, drive any. Limit (docs/architecture.md): a program that
    /// has an app start one for the user to watch (`open -a Terminal`), and files left for the user to run.
    static func allow(
        _ method: any Answered, caller: Caller, store: Store, live: SessionTable, databases: Databases
    ) throws {
        try FenceCheck(store: store, live: live, databases: databases).allow(method, caller)
    }
}

/// `AgentRules.allow`'s reads: the records, the sessions running now (one that asks a question), and the databases an
/// agent may use (a tab of one).
private struct FenceCheck {
    let store: Store, live: SessionTable, databases: Databases

    func allow(_ method: any Answered, _ caller: Caller) throws {
        switch caller {
        case .user: return
        case .session(let own):
            if let id = method.fence.reportsFor, own != id {
                throw RPCError.refused("A session speaks only for itself.")
            }
            guard try store.forAnAgent(own) else { return }
            try allowAgent(method, own: own)
        case .typedAgent(let own):
            if let id = method.fence.reportsFor, own != id {
                throw RPCError.refused("A session speaks only for itself.")
            }
            try allowAgent(method, own: own, typed: true)
        case .unknown:
            // Looked up as it connects, a hook waiting for its answer is always found: one gone by then handed its
            // connection on, which is how a program would speak for a session not its own.
            try allowAgent(
                method, own: Callers.unknown,
                or: "Kelp couldn't tell which program sent this (it ended as it connected), so it may not do that.")
        case .kelpd:
            try allowAgent(
                method, own: Callers.ownProgram,
                or:
                    "A program Kelp runs (an extension's command or event, a repo's git hook) may not do that: it has no session to act for."
            )
        case .detached:
            try allowAgent(
                method, own: Callers.detached,
                or: "Kelp can't tell this program is yours (it runs outside every terminal and app: in the background, "
                    + "a launchd job, a tmux pane out of sight), so it's held to an agent's rules: run it from a terminal of yours."
            )
        }
    }

    /// One with no session of its own (`Caller.kelpd` and the like): no report, and an agent's rules. Refused in `why`'s
    /// words, then the rule's own (`SessionCreate`'s tmux…); anything else (the store) as it is.
    func allowAgent(_ method: any Answered, own: String, or why: String) throws {
        if method.fence.reportsFor != nil { throw RPCError.refused(why) }
        do { try allowAgent(method, own: own) } catch let error as RPCError where error.isRefusal {
            throw RPCError.refused(why + " " + error.message)
        }
    }

    /// What a program of an agent's (or of the daemon's, `own` = `Callers.ownProgram`) may not do.
    /// `typed`: an agent the user typed into `own`, a terminal of theirs: what it reaches is what it started there
    /// (`typed:` on its line), not everything the user started from that terminal.
    func allowAgent(_ method: any Answered, own: String, typed: Bool = false) throws {
        if method.fence.signs, method.fence.reportsFor == nil {
            throw RPCError.refused(
                "What an agent writes for others says it's an agent's: run it from the agent's terminal, which names its session."
            )
        }
        func reaches(_ id: String) throws -> Bool {
            try store.lineage(id).contains {
                typed ? Caller.started($0.origin, byAgentTypedInto: own) : $0.id == own
            }
        }
        if let refusal = method.fence.notForAgents { throw RPCError.refused(refusal) }
        if method.fence.answersQuestion {
            throw RPCError.refused(
                "An agent's question is the user's to answer: in Kelp's window, or `kelp agents` in a terminal of theirs."
            )
        }
        let name = type(of: method).name
        guard AgentRules.methods.contains(name) else {
            throw RPCError.refused(
                "“\(name)” is the user's: an agent's program may call only what agents use (AgentRules.methods).")
        }
        if let id = method.fence.typesInto, live[id]?.asksSomething == true {
            throw RPCError.refused(
                "That session asks a question, the user's to answer; send again once it's answered, or tell the user "
                    + "what you'd answer.")
        }
        // The user's accounts (`accounts.*`) are theirs to pick: what an agent starts runs under its own.
        if let launch = method as? any LaunchOptions, let profile = launch.profile,
            try profile != store.session(own)?.profile
        {
            throw RPCError.refused(
                "An agent starts sessions under its own account, not another of the user's: leave out `profile`, or "
                    + "ask the user to start it from Kelp's window.")
        }
        // The first local page such a session prints opens by itself as a plain page tab, logged in as the user, which
        // `UIOpen` refuses an agent for that reason: what an agent serves, it opens with cookies of its own.
        if (method as? any LaunchOptions)?.openURLs == true {
            throw RPCError.refused(
                "A page that opens by itself (`openURLs`) is logged in as the user: leave it out, and open what the "
                    + "session serves with `kelp browser open <url>`, which gives it cookies of its own.")
        }
        // A typed agent's own session is the user's terminal it was typed into: it names it as anyone in it would (a child's
        // parent, its reports, its tab), but neither types into it nor acts on it (Stop, Restart, a question there).
        func itsOwn(_ id: String) -> Bool {
            id == own && !(typed && (id == method.fence.typesInto || id == method.fence.actsOn))
        }
        for id in Set([method.fence.actsOn, method.fence.shows].compactMap { $0 } + (try store.named(by: method)))
        where !itsOwn(id) {
            guard try reaches(id) else {
                throw RPCError.refused(
                    "An agent acts only on its own session and the sessions it started: start one with `kelp session "
                        + "new`, or ask the user to do this one.")
            }
        }
        // Every workspace a call that acts names, whatever the field: not each method remembering to say. `inWorkspace` is
        // for what the walk can't see (the workspace on screen, `""`) and for a read held to the agent's own (a fetch).
        let held = try method.fence.writesInFolder.flatMap { folder in
            IDE.workspace(
                cwd: folder, among: try store.worktrees().filter { !$0.archived },
                own: try store.session(own)?.worktreeId)?.id
        }
        let workspaces = Set(
            [method.fence.inWorkspace, held].compactMap { $0 }
                + (AgentRules.reads.contains(name) ? [] : try store.workspaces(namedBy: method)))
        for workspace in workspaces where try !store.works(own, in: workspace, typed: typed) {
            throw RPCError.refused(
                "An agent works only in its own workspace: make one with `kelp worktree create <branch>`, or ask the "
                    + "user to do this there.")
        }
        // A database's tab reads its tables and rows as the user, and `kelp shot` hands the agent the picture: only of
        // one the agent may read itself (`Databases.connection`: what `db.list` gives it, and not an address from the
        // project's files before the user opened it, which the tab would have kelpd dial). That one's refusal says why.
        if let tab = (method as? UIOpen).flatMap({ DatabaseTabURI.parts($0.uri) }) {
            do { _ = try databases.connection(tab.worktree, tab.name, agent: true) } catch let error as RPCError
                where !error.isRefusal
            {
                throw RPCError.refused("An agent opens a tab only of a database it may use: `kelp db list` says which.")
            }
        }
        if let repo = method.fence.makesInProject,
            try !store.worktrees(repo: repo).contains(where: {
                try store.works(own, in: $0.id, typed: typed)
            })
        {
            throw RPCError.refused("An agent makes workspaces only in the project it works in.")
        }
        if let ending = method.fence.ends,
            try store.ending(ending).contains(where: { session in
                try (typed || session != own) && !reaches(session)
            })
        {
            throw RPCError.refused("An agent ends only its own sessions and the ones it started.")
        }
    }
}

/// What the fence reads of a call (`AgentRules.allow`): the sessions and workspaces it names, where an agent works, what a
/// removal ends. From the records, as `lineage` is.
extension Store {
    /// The sessions a call names, in any field (an `id`, a `session`, a `parent`, a list of them, a struct's or an
    /// enum's in turn): what an agent's call may reach is decided by what it names, not by each method remembering to
    /// say. Free-form JSON (`JSONValue`: a setting's value, a command's args) and bytes name none.
    func named(by params: Any) throws -> [String] {
        return try ids(params).filter { try session($0) != nil }
    }

    /// The workspaces a call names, in any field, as `named(by:)` finds sessions.
    func workspaces(namedBy params: Any) throws -> [String] { try ids(params).filter { try worktree($0) != nil } }

    /// Every id-shaped string in a call's params, at any depth (`named(by:)`'s walk).
    private func ids(_ params: Any) throws -> [String] {
        func strings(_ value: Any, depth: Int) throws -> [String] {
            if let string = value as? String { return [string] }
            guard !(value is JSONValue), !(value is Data) else { return [] }
            let parts = Mirror(reflecting: value).children
            // Deeper than any method's params go: refused, not taken for naming nobody.
            guard depth < 6 || parts.isEmpty else {
                throw RPCError.refused("Kelp can't tell which sessions this call names.")
            }
            return try parts.flatMap { try strings($0.value, depth: depth + 1) }
        }
        return try strings(params, depth: 0).filter { UUID(uuidString: $0) != nil }
    }

    /// Whether `workspace` is the workspace of `own` or of one that started it, one they made, or one a session it
    /// started works in (which it could start there only for one of those): an agent works there only.
    /// `typed`: an agent typed into `own`, the user's terminal: its workspace (it runs there), and the ones it made or
    /// started a session in, not those the user made or worked in from that terminal.
    func works(_ own: String, in workspace: String, typed: Bool = false) throws -> Bool {
        let line = try lineage(own)
        if line.contains(where: { $0.worktreeId == workspace }) { return true }
        let maker = try worktree(workspace)?.madeBy
        if typed {
            if Caller.started(maker, byAgentTypedInto: own) { return true }
        } else if let makerSession = Caller.session(of: maker), line.contains(where: { $0.id == makerSession }) {
            return true
        }
        return try sessions(in: [workspace]).contains { session in
            try lineage(session.id).contains {
                typed ? Caller.started($0.origin, byAgentTypedInto: own) : $0.id == own
            }
        }
    }

    /// The sessions removing `target` ends: those of the workspace, or of every workspace of the project.
    func ending(_ target: Ending) throws -> [String] {
        let ids: Set<String> =
            switch target {
            case .workspace(let workspace): [workspace]
            case .project(let repo): Set(try worktrees(repo: repo).map(\.id))
            }
        return try sessions(in: ids).map(\.id)
    }

    /// The sessions of these workspaces, by a query: an agent's call reads only those, not every session kept.
    private func sessions(in workspaces: Set<String>) throws -> [Session] {
        try db.read { try Session.filter(workspaces.contains(Column("worktreeId"))).fetchAll($0) }
    }
}
