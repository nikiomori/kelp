import AgentData
import Core
import Foundation
import GitKit

// Where an agent worked (`session.work`): its conversation, its subagents', and those of the agents it started, read
// through `WorkIndex`, put together by `WorkMap`.

extension SessionWork: Handled {
    static let agents = AgentAccess.reads
    func handle(_ reader: WorkReader) throws -> Result {
        guard let session = try reader.session(id), let found = try reader.sources(session),
            let main = found.sources.first
        else { return nil }
        let changed = whole == true ? [] : reader.turnChanges(session, turn: turn, prompts: main.log.prompts)
        return WorkMap.build(
            found.sources, places: found.places, turn: turn, whole: whole == true,
            working: session.status == .working, changed: changed)
    }
}

extension Methods {
    static let workMethods: [any Answered.Type] = [SessionWork.self]
}

/// What `session.work` and its watch read: the live sessions (for a transcript a hook named), the store (the agents a
/// session started, its turns' snapshots, its project's folder), and the conversations.
struct WorkReader {
    let live: SessionTable, usage: AgentUsage
    var store: Store { usage.store }
    var remotes: Remotes { usage.remotes }

    init(_ live: SessionTable, _ usage: AgentUsage) {
        self.live = live
        self.usage = usage
    }

    func session(_ id: String) throws -> Session? { try live[id]?.snapshot ?? store.session(id) }

    /// The conversations behind a session's work, the session's own first, and where its project is. nil when its
    /// agent keeps no conversation Kelp reads, or a host's isn't reachable now.
    func sources(_ session: Session) throws -> (sources: [WorkMap.Source], places: WorkMap.Places)? {
        if let remote = usage.conversations.host(of: session) { return hostSources(session, path: remote.path) }
        let conversations = usage.conversations, index = usage.work
        let found = live[session.id]
        guard
            let file = found?.transcriptPath.map(URL.init(fileURLWithPath:))
                ?? conversations.conversationFile(of: session, live: found),
            let log = index.log(file)
        else { return nil }
        let agent = session.agent ?? ""
        var sources = [WorkMap.Source(agent: .init(role: .main, agent: agent, name: agent), log: log)]
        let subagents = file.deletingPathExtension().appendingPathComponent("subagents")
        for sub in FileManager.default.items(in: subagents).filter({ $0.pathExtension == "jsonl" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            guard let subLog = index.log(sub) else { continue }
            let meta = FileManager.default.contents(atPath: sub.deletingPathExtension().path + ".meta.json")
            let name = sub.deletingPathExtension().lastPathComponent
            sources.append(Self.subagent(name, meta: meta, agent: agent, log: subLog))
        }
        for child in try store.children(of: [session.id]) {
            guard let childAgent = child.agent,
                let childFile = conversations.conversationFile(of: child, live: live[child.id]),
                let childLog = index.log(childFile)
            else { continue }
            let role = AgentWork.Agent(
                role: .child, agent: childAgent, name: childAgent, task: child.title, id: child.id)
            sources.append(WorkMap.Source(agent: role, log: childLog))
        }
        let root = try session.worktreeId.flatMap { try store.worktree($0)?.path } ?? log.cwd ?? session.cwd
        return (sources, WorkMap.Places(root: root, home: NSHomeDirectory(), remote: WorkMap.Places.remote(of: root)))
    }

    /// A subagent's source, from its file's name (`agent-<id>`) and its `.meta.json`.
    static func subagent(_ name: String, meta: Data?, agent: String, log: WorkLog) -> WorkMap.Source {
        let fields =
            meta.flatMap { data in
                Log.session.attempt("reading \(name)'s kind") {
                    try JSONSerialization.jsonObject(with: data) as? [String: Any]
                } ?? nil
            } ?? [:]
        let id = name.hasPrefix("agent-") ? String(name.dropFirst("agent-".count)) : name
        let role = AgentWork.Agent(
            role: .subagent, agent: agent, name: fields["agentType"] as? String ?? "Subagent",
            task: fields["description"] as? String, id: id)
        return WorkMap.Source(agent: role, log: log, startedBy: fields["toolUseId"] as? String)
    }

    /// A remote Claude Code's conversation and its subagents', read on the host through the open connection, each from
    /// where it was read last. Its paths are the host's, so the project's root is the folder the agent began in.
    /// Limit: the agents it started aren't read on the host, nor Codex.
    private func hostSources(_ session: Session, path: String) -> (sources: [WorkMap.Source], places: WorkMap.Places)? {
        let index = usage.work, key = "host:\(session.id):"
        let offsets = Dictionary(uniqueKeysWithValues: index.keys(prefix: key).map { ($0, index.entry(key + $0).read) })
        guard let files = usage.conversations.remoteWork(of: session, offsets: offsets) else { return nil }
        var metas: [String: Data] = [:], names: [String] = []
        for file in files {
            if file.name.hasPrefix("meta:") {
                metas[String(file.name.dropFirst("meta:".count))] = file.data
                continue
            }
            var entry = index.entry(key + file.name)
            if file.start != entry.read || file.size < entry.read {
                entry = WorkIndex.Entry()
                entry.base = file.start
            }
            entry.log.read(file.data)
            index.keep(key + file.name, entry)
            names.append(file.name)
        }
        guard names.contains("main") else { return nil }
        let agent = session.agent ?? "", main = index.entry(key + "main").log
        var sources = [WorkMap.Source(agent: .init(role: .main, agent: agent, name: agent), log: main)]
        for name in names.filter({ $0 != "main" }).sorted() {
            sources.append(Self.subagent(name, meta: metas[name], agent: agent, log: index.entry(key + name).log))
        }
        let root = main.cwd ?? path
        let home = root.firstMatch(of: /^\/(?:home|Users)\/[^\/]+/).map { String($0.0) } ?? "/root"
        return (sources, WorkMap.Places(root: root, home: home))
    }

    /// What changed in a finished turn by the snapshots Kelp took at its start and the next turn's start (the last
    /// turn's end, for the last), so a file a command changed counts too. Git runs where the project is, on its host
    /// for a remote one. Empty while the turn goes on and for a turn Kelp kept no snapshot of.
    func turnChanges(_ session: Session, turn: Int?, prompts: [WorkLog.Prompt]) -> [WorkMap.Changed] {
        guard !prompts.isEmpty, session.status != .working else { return [] }
        let picked = turn.map { min(max($0, 0), prompts.count - 1) } ?? prompts.count - 1
        let start = prompts[picked].at, end = picked + 1 < prompts.count ? prompts[picked + 1].at : Date.distantFuture
        if picked == prompts.count - 1, let last = live[session.id]?.lastTurn {
            return last.files.map { WorkMap.Changed(path: $0.path, added: $0.added, removed: $0.removed) }
        }
        let marks = (Log.store.attempt("reading \(session.id)'s turns") { try store.turns(session: session.id) } ?? [])
            .sorted { $0.at < $1.at }
        guard let from = marks.firstIndex(where: { $0.at >= start.addingTimeInterval(-5) && $0.at < end }),
            from + 1 < marks.count,
            // The next snapshot must be this turn's end: one taken later holds a later turn's changes too.
            marks[from + 1].at <= end.addingTimeInterval(5)
        else { return [] }
        let (a, b) = (marks[from], marks[from + 1])
        let out = Log.session.attempt("reading turn \(a.id)'s changes") {
            try Git.run(["diff", "--numstat", "--no-renames", "-z", a.tree, b.tree], cwd: a.folder, remotes: remotes)
        }
        return (out ?? "").split(separator: "\0").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            return WorkMap.Changed(path: String(fields[2]), added: Int(fields[0]) ?? 0, removed: Int(fields[1]) ?? 0)
        }
    }

    /// The watch's event: its stamp changes whenever any conversation behind the session's work grows.
    func event(_ id: String) throws -> WorkEvent? {
        guard let session = try session(id), let found = try sources(session) else { return nil }
        let stamp = found.sources.map { "\($0.log.offset):\($0.log.calls.count)" }.joined(separator: ",")
        return WorkEvent(session: id, stamp: stamp)
    }
}
