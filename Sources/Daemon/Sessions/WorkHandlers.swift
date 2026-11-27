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
        // "Now" is the last turn's: an earlier turn, or the whole session, has none while the agent works on.
        let last = turn.map { $0 >= main.log.prompts.count - 1 } ?? true
        return WorkMap.build(
            found.sources, places: found.places, turn: turn, whole: whole == true,
            working: session.status == .working && whole != true && last, changed: changed)
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
        if let remote = usage.conversations.host(of: session) {
            // One host read at a time per session, its answer kept a moment for the views asking with it; one asking
            // while another's ssh runs takes the last answer rather than wait for it.
            let key = "host:\(session.id)", index = usage.work
            return index.ifFree(key) { index.recent(key, fresh: 1.5) { hostSources(session, path: remote.path) } }
                ?? index.kept(key)
        }
        let conversations = usage.conversations, index = usage.work
        let found = live[session.id]
        guard
            let file = found?.transcriptPath.map(URL.init(fileURLWithPath:))
                // Found by looking (lsof for a live Codex): kept a while, its file doesn't change.
                ?? index.recent(
                    "file:\(session.id)", fresh: WorkIndex.idle,
                    { conversations.conversationFile(of: session, live: found) }),
            let log = index.log(file),
            // A file read through with no prompt or call in it is a transcript `WorkLog` can't read (another agent's
            // format): no transcript, not a turn that touched nothing.
            !(log.offset > 0 && log.prompts.isEmpty && log.calls.isEmpty)
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
                // The live agent's own path first: finding its file otherwise asks pgrep and lsof, on every pass.
                let childFile = live[child.id]?.transcriptPath.map(URL.init(fileURLWithPath:))
                    ?? index.recent(
                        "file:\(child.id)", fresh: WorkIndex.idle,
                        { conversations.conversationFile(of: child, live: live[child.id]) }),
                let childLog = index.log(childFile)
            else { continue }
            let role = AgentWork.Agent(
                role: .child, agent: childAgent, name: childAgent, task: child.title, id: child.id)
            sources.append(WorkMap.Source(agent: role, log: childLog))
        }
        let root = try session.worktreeId.flatMap { try store.worktree($0)?.path } ?? log.cwd ?? session.cwd
        return (sources, WorkMap.Places(root: root, home: NSHomeDirectory(), remote: Git.originHost(root)))
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
            let entry = WorkIndex.continued(
                index.entry(key + file.name), start: file.start, size: file.size, data: file.data)
            index.keep(key + file.name, entry)
            names.append(file.name)
        }
        guard let mainName = names.first(where: { $0.hasPrefix("main.") }) else { return nil }
        let agent = session.agent ?? "", main = index.entry(key + mainName).log
        var sources = [WorkMap.Source(agent: .init(role: .main, agent: agent, name: agent), log: main)]
        for name in names.filter({ $0 != mainName }).sorted() {
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
        guard !prompts.isEmpty else { return [] }
        let picked = turn.map { min(max($0, 0), prompts.count - 1) } ?? prompts.count - 1
        // Only the turn still going on has no end to compare with: an earlier one's changes are known.
        if session.status == .working, picked == prompts.count - 1 { return [] }
        let start = prompts[picked].at, end = picked + 1 < prompts.count ? prompts[picked + 1].at : Date.distantFuture
        if picked == prompts.count - 1, let last = live[session.id]?.lastTurn {
            return last.files.map { WorkMap.Changed(path: $0.path, added: $0.added, removed: $0.removed) }
        }
        let marks = Log.store.attempt("reading \(session.id)'s turns") { try store.turns(session: session.id) } ?? []
        guard let (a, b) = Self.snapshots(marks, start: start, end: end) else { return [] }
        // Two snapshots' difference never changes: kept, so an earlier turn shown while the agent works isn't diffed
        // again on every pass.
        let out = usage.work.recent("diff:\(a.tree):\(b.tree)", fresh: WorkIndex.idle) {
            Log.session.attempt("reading turn \(a.id)'s changes") {
                try Git.run(
                    ["diff", "--numstat", "--no-renames", "-z", a.tree, b.tree], cwd: a.folder, remotes: remotes)
            }
        }
        return (out ?? "").split(separator: "\0").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            return WorkMap.Changed(path: String(fields[2]), added: Int(fields[0]) ?? 0, removed: Int(fields[1]) ?? 0)
        }
    }

    /// The snapshots a turn from `start` to `end` began and ended with: the oldest taken as it began, and the next, if
    /// that one was taken as it ended (one taken later holds a later turn's changes too).
    static func snapshots(_ marks: [SessionTurns.Mark], start: Date, end: Date) -> (
        SessionTurns.Mark, SessionTurns.Mark
    )? {
        let marks = marks.sorted { $0.at < $1.at }
        guard let from = marks.firstIndex(where: { $0.at >= start.addingTimeInterval(-5) && $0.at < end }),
            from + 1 < marks.count, marks[from + 1].at <= end.addingTimeInterval(5)
        else { return nil }
        return (marks[from], marks[from + 1])
    }

    /// The watch's stamp: it changes when a prompt, a call or a call's result is added to any conversation behind the
    /// work (not with every line written), when the status changes, and when a turn's end is known.
    static func stamp(_ logs: [WorkLog], status: AgentStatus, ended: Int?) -> String {
        let counts = logs.map {
            "\($0.prompts.count):\($0.calls.count):\($0.calls.lazy.filter { $0.done != nil }.count)"
        }
        return counts.joined(separator: ",") + " \(status.rawValue) \(ended.map(String.init) ?? "-")"
    }

    /// The watch's event: its stamp changes whenever any conversation behind the session's work grows.
    func event(_ id: String) throws -> WorkEvent? {
        guard let session = try session(id) else { return nil }
        // A host's agent that isn't working won't grow its files: no ssh read each pass for it. Its stamp changes when
        // it stops, so what it wrote last is read once more.
        if usage.conversations.host(of: session) != nil, session.status != .working {
            return WorkEvent(session: id, stamp: "idle")
        }
        guard let found = try sources(session) else { return nil }
        // With its status and the turn's end: a turn that stopped after its last write is read again, for where it is
        // now and the files its commands changed.
        let stamp = Self.stamp(found.sources.map(\.log), status: session.status, ended: live[id]?.lastTurn?.files.count)
        return WorkEvent(session: id, stamp: stamp)
    }
}
