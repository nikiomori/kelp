import Core
import Foundation
import GRDB

/// What an agent's program may do with a method. Each handler says it once (`Answered.agents`, beside its `fence`).
/// Everything else is the user's alone (commits, pushes, PRs, CI, trackers, credentials, projects, scripts, the daemon
/// itself), so a method that says nothing is closed to agents.
enum AgentAccess {
    /// The method is the user's alone.
    case none
    /// The method only reads, so the workspace it names may be any one (a review of another branch, a status).
    case reads
    /// The method acts, so every session and workspace it names, in any field, must be the agent's own
    /// (`Store.named(by:)`, `Store.workspaces(namedBy:)`). Each method still has its own rules as well (`actsOn`,
    /// `inWorkspace`, …).
    case acts
}

/// What an agent's program may reach: the methods it may call (`methods`, kept beside the daemon's table of methods),
/// and the rules every call is held to (`allow`, which `Daemon.allow` asks for every call).
enum AgentRules {
    /// Checks what `caller` may reach with this call (`Daemon.allow`, which every path asks).
    /// A report comes from inside a session, told by its process tree, and only for that session. A program an agent
    /// runs, or runs in a terminal the agent started, reads, types into, stops and answers for only the sessions that
    /// agent started. The daemon knows who started what (`parent`, `startedBy`, `origin`) from the caller's process.
    /// Any session a call names, in any of its fields, counts, so a method needn't remember to say so. These are held
    /// to the same rules with no session of their own: a program the daemon started (an extension's, a git hook), a
    /// program gone before it was looked at, and a program Kelp can't tell is the user's (`Caller.detached`). A program
    /// under an agent the user typed into a terminal (`Caller.typedAgent`) is held to them as that terminal's agent. A
    /// program whose own session's record is gone (the old session of a restart) is held to them as an agent in no
    /// session (`forAnAgent`). The user's own terminals, and programs under an app, drive any session.
    /// Limit (docs/architecture.md): this doesn't cover a program that has an app start a program for the user to watch
    /// (`open -a Terminal`), or files left for the user to run.
    static func allow(
        _ method: any Answered, caller: Caller, store: Store, live: SessionTable, databases: Databases
    ) throws {
        try FenceCheck(store: store, live: live, databases: databases).allow(method, caller)
    }
}

/// What `AgentRules.allow` reads: the records, the sessions running now (to see one that asks a question), and the
/// databases an agent may use (for a database tab).
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
            // A caller is looked up as it connects, so a hook that waits for its answer is always found. A caller gone
            // by then handed its connection on, which is how a program would speak for a session not its own.
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

    /// Checks a caller with no session of its own (`Caller.kelpd` and the like). It may send no report and is held to
    /// an agent's rules. A refusal says `why` first, then the rule's own words (`SessionCreate`'s tmux…). Any other
    /// error (from the store) is thrown as it is.
    func allowAgent(_ method: any Answered, own: String, or why: String) throws {
        if method.fence.reportsFor != nil { throw RPCError.refused(why) }
        do { try allowAgent(method, own: own) } catch let error as RPCError where error.isRefusal {
            throw RPCError.refused(why + " " + error.message)
        }
    }

    /// Refuses what a program run by an agent (or by the daemon, when `own` is `Callers.ownProgram`) may not do.
    /// `typed` means an agent the user typed into `own`, one of the user's terminals. Such an agent reaches only what
    /// it started there (its lineage carries `typed:`), not everything the user started from that terminal.
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
        // The user picks between their accounts (`accounts.*`), so what an agent starts runs under the agent's own.
        if let launch = method as? any LaunchOptions, let profile = launch.profile,
            try profile != store.session(own)?.profile
        {
            throw RPCError.refused(
                "An agent starts sessions under its own account, not another of the user's: leave out `profile`, or "
                    + "ask the user to start it from Kelp's window.")
        }
        // With `openURLs`, the first local page the session prints opens by itself as a plain page tab, logged in as
        // the user. `UIOpen` refuses an agent that for the same reason, so an agent opens what it serves with cookies
        // of its own.
        if (method as? any LaunchOptions)?.openURLs == true {
            throw RPCError.refused(
                "A page that opens by itself (`openURLs`) is logged in as the user: leave it out, and open what the "
                    + "session serves with `kelp browser open <url>`, which gives it cookies of its own.")
        }
        // A typed agent's own session is the user's terminal it was typed into. The agent may name that session as
        // anything in it would (a child's parent, its reports, its tab), but it neither types into it nor acts on it
        // (Stop, Restart, a question there).
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
        // This checks every workspace that an acting call names, in any field, so no method has to remember to say it.
        // `inWorkspace` is for what the walk can't see (the workspace on screen, `""`) and for a read held to the
        // agent's own workspace (a fetch).
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
        // A database tab reads its tables and rows as the user, and `kelp shot` hands the agent the picture. So an
        // agent opens a tab only of a database it may read itself (`Databases.connection`: what `db.list` gives it).
        // That excludes an address from the project's files that the user hasn't opened yet, which the tab would have
        // kelpd dial, and a database whose structure only agents see, whose rows the tab shows. A refusal says why.
        if let tab = (method as? UIOpen).flatMap({ DatabaseTabURI.parts($0.uri) }) {
            do {
                if try databases.connection(tab.worktree, tab.name, agent: true).database.agentAccess == .structure {
                    throw RPCError.refused("\(tab.name) shows agents its structure only: a tab would show its rows.")
                }
            } catch let error as RPCError where !error.isRefusal {
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

/// What the fence (`AgentRules.allow`) reads about a call: the sessions and workspaces it names, where an agent works,
/// and what a removal ends. All of it is read from the records, as `lineage` is.
extension Store {
    /// The sessions a call names, in any field: an `id`, a `session`, a `parent`, a list of them, or a field inside a
    /// struct or an enum, in turn. What an agent's call may reach is decided by what it names, so no method has to
    /// remember to declare it. Free-form JSON (`JSONValue`: a setting's value, a command's args) and raw bytes name no
    /// session.
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
            // Params nested deeper than any method's are refused, not taken to name nobody.
            guard depth < 6 || parts.isEmpty else {
                throw RPCError.refused("Kelp can't tell which sessions this call names.")
            }
            return try parts.flatMap { try strings($0.value, depth: depth + 1) }
        }
        return try strings(params, depth: 0).filter { UUID(uuidString: $0) != nil }
    }

    /// Whether an agent may work in `workspace`. It may in the workspace of `own` or of a session that started it, in a
    /// workspace they made, and in one where a session `own` started works (it could only start one there in those).
    /// With `typed`, an agent typed into `own` (the user's terminal) may work in that terminal's workspace, where it
    /// runs, and in the ones it made or started a session in. It may not work in those the user made or worked in from
    /// that terminal.
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

    /// The sessions that removing `target` ends: those of the workspace, or of every workspace in the project.
    func ending(_ target: Ending) throws -> [String] {
        let ids: Set<String> =
            switch target {
            case .workspace(let workspace): [workspace]
            case .project(let repo): Set(try worktrees(repo: repo).map(\.id))
            }
        return try sessions(in: ids).map(\.id)
    }

    /// The sessions in these workspaces, read by a query, so an agent's call reads only those, not every session kept.
    private func sessions(in workspaces: Set<String>) throws -> [Session] {
        try db.read { try Session.filter(workspaces.contains(Column("worktreeId"))).fetchAll($0) }
    }
}
