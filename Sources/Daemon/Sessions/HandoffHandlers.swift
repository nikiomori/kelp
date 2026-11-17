import AgentData
import Agents
import Core
import Foundation
import GitKit
import Integrations

extension SessionHandoff: Handled {
    static let agents = AgentAccess.acts
    func handle(_ sessions: Sessions) throws -> Session {
        guard let old = try sessions.store.session(id) else { throw RPCError.noSession(id) }
        return try start(from: old, in: old.cwd, worktreeId: old.worktreeId, sessions)
    }

    /// Starts the next agent, briefed with `old`'s work, in `cwd`: the old session's own folder, or where a moved chat
    /// goes on (here or on a host, `session.moveAcross`).
    func start(from old: Session, in cwd: String, worktreeId: String?, _ sessions: Sessions) throws -> Session {
        let target = agent ?? old.agent, remote = sessions.remotes.of(old.cwd), there = sessions.remotes.of(cwd)
        var manifest = try sessions.setup.manifest(target, command: nil)
        // A remote agent's conversation is on its host, so its end is brought here to write the brief from.
        let file =
            remote.map { Self.hostCopy(of: old, on: $0, sessions) }
            ?? sessions.agentUsage.conversations.conversationFile(of: old, live: sessions.existing(old.id))
        let uncommitted = Self.uncommitted(old.cwd, sessions)
        let ask = prompt ?? "Continue the task where the previous agent left off."
        var launch = Sessions.Launch(self)
        launch.title = (old.title.isEmpty ? (old.agent ?? "agent") : old.title) + " (handoff)"
        if remote == nil, there == nil,
            let opened = try native(old, manifest, file: file, at: (cwd, uncommitted), sessions)
        {
            manifest.args += opened
            launch.prompt = ask
        } else {
            let conversation = file.flatMap(Conversation.init(file:))
            let brief = try Self.brief(of: old, conversation, limit: limit, uncommitted: uncommitted, sessions)
            // The next agent runs in `cwd`: on a host, the brief goes there for it to read.
            let path = try there.map { try Self.upload(brief, to: $0) } ?? brief.path
            launch.prompt = "Read \(path) — the transcript of the previous agent session in this project. " + ask
        }
        return try sessions.spawn(cwd: cwd, manifest: manifest, worktreeId: worktreeId, launch)
    }

    private var limit: Int { full == true ? 400_000 : 40_000 }

    /// The arguments `agent` starts with to open the conversation as its own. Returns nil when it can't, and then the
    /// agent reads the brief instead. Codex imports a Claude Code transcript itself, as a thread it resumes (only into
    /// the default account, because another account's Codex wouldn't find it). pi and oh-my-pi open a session file in
    /// their own format that Kelp writes, and they go on in it.
    private func native(
        _ old: Session, _ manifest: AgentManifest, file: URL?, at place: (cwd: String, uncommitted: String),
        _ sessions: Sessions
    ) throws -> [String]? {
        let (cwd, uncommitted) = place
        switch manifest.transcript {
        case .codex? where sessions.setup.transcript(of: old.agent) == .claude && profile == nil:
            return file.flatMap { sessions.agentUsage.conversations.codexThread(importing: $0, cwd: cwd) }.map {
                ["resume", $0]
            }
        case .pi?:
            guard let conversation = file.flatMap(Conversation.init(file:)), let flag = manifest.resumeIdFlag else {
                return nil
            }
            let session = try conversation.piSession(
                cwd: cwd, agent: old.agent ?? "agent", limit: limit, uncommitted: uncommitted)
            // A new file for each hand-off, because the agent writes on in it and an earlier one may still be open.
            let path = try Self.handoffFile("\(old.id)-\(UUID().uuidString.prefix(8).lowercased()).jsonl", sessions)
            try session.write(to: path, atomically: true, encoding: .utf8)
            return [flag, path.path]
        default: return nil
        }
    }

    /// Writes a session's conversation to ~/.kelp/handoff/<id>.md for the next agent to read: the agent's own
    /// conversation (what was asked and answered, what it changed and ran, for Claude Code, Codex and pi) when there is
    /// one, otherwise the terminal's text. Either way it adds what git says is uncommitted.
    private static func brief(
        of session: Session, _ conversation: Conversation?, limit: Int, uncommitted: String, _ sessions: Sessions
    ) throws -> URL {
        let body: String
        if let conversation {
            body = conversation.markdown(limit: limit, uncommitted: uncommitted)
        } else {
            let printed = try sessions.liveSessionOrLog(session.id, bytes: limit)
            // Lossy on purpose, see session.context.
            // swiftlint:disable:next optional_data_string_conversion
            body = [
                "```\n" + StatusDetector.stripANSI(String(decoding: printed, as: UTF8.self)) + "\n```",
                Conversation().notes(uncommitted: uncommitted)
            ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let file = try handoffFile("\(session.id).md", sessions)
        try ("# Previous session (\(session.agent ?? "agent"), \(session.cwd))\n\n" + body + "\n").write(
            to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Copies the end of a remote Claude Code's conversation (`Conversations.remoteTail`, over the open connection)
    /// into a file here. Returns nil without a connection, and then the brief is the session's screen.
    private static func hostCopy(of session: Session, on remote: RemoteHost, _ sessions: Sessions) -> URL? {
        guard let tail = sessions.agentUsage.conversations.remoteTail(of: session, on: remote) else { return nil }
        return Log.session.attempt("keeping \(session.id)'s conversation from its host") {
            let file = try handoffFile("\(session.id)-host.jsonl", sessions)
            try tail.write(to: file, options: .atomic)
            return file
        }
    }

    /// Copies the brief into the repository's own .git/kelp-handoff on the host (git doesn't list it; a worktree uses
    /// its project's), where the agent on the host reads it, and returns its path there.
    private static func upload(_ brief: URL, to remote: RemoteHost) throws -> String {
        let name = ShellQuote.word(brief.lastPathComponent)
        let out = try remote.run(
            "cd \(RemoteHost.cdArg(remote.path)) && "
                + #"d="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/kelp-handoff"; mkdir -p "$d" && "#
                + #"cat > "$d/"\#(name) && printf %s "$d/"\#(name)"#,
            stdin: try Data(contentsOf: brief), timeLimit: 60)
        return String(decoding: out, as: UTF8.self)
    }

    private static func handoffFile(_ name: String, _ sessions: Sessions) throws -> URL {
        let dir = sessions.root.appendingPathComponent("handoff")
        try Paths.ensure(dir)
        return dir.appendingPathComponent(name)
    }

    /// `git status --short` in `cwd`, its first 60 lines.
    private static func uncommitted(_ cwd: String, _ sessions: Sessions) -> String {
        do {
            let status = try Git.run(["status", "--short"], cwd: cwd, remotes: sessions.remotes)
            return status.split(separator: "\n").prefix(60).joined(separator: "\n")
        } catch {
            return ""   // not a repository: nothing to say
        }
    }
}
