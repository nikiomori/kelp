import AgentData
import Agents
import Core
import Foundation
import os

/// Where each session's agent keeps its conversation, and what reads it: the transcript of a Claude Code session, the
/// rollout a Codex has open, a pi's session file, the last reply of any of them, and the Codex thread a Claude Code
/// transcript becomes. AgentData reads what's in the files; this class knows which file belongs to which session. A
/// remote project's Claude Code keeps its conversation on the host, so its last bytes are read there (`remoteTail`).
final class Conversations: Sendable {
    let settings: SettingsStore
    let remotes: Remotes   // which session folders stand for a folder on a host
    /// The usage probes running now (shared with `AgentUsage`). Codex's import runs as one, so it ends when the daemon
    /// ends.
    let openProbes: OpenProbes
    /// The default folders where Claude Code and Codex keep their conversations, not counting account profiles (tests
    /// set it before the first call).
    let homes = OSAllocatedUnfairLock(
        initialState: (claude: ClaudeHistory.defaultRoot, codex: CodexHistory.defaultRoot))

    /// Claude Code's folder on a host, quoted for sh. Tests set their own, because their host is this Mac, where
    /// `~/.claude` is the user's.
    let hostClaude = OSAllocatedUnfairLock(initialState: #""${CLAUDE_CONFIG_DIR:-$HOME/.claude}""#)

    init(settings: SettingsStore, openProbes: OpenProbes, remotes: Remotes) {
        self.settings = settings
        self.remotes = remotes
        self.openProbes = openProbes
    }

    /// Default roots plus each account profile's config dir.
    func roots() -> (claude: [URL], codex: [URL]) {
        let homes = homes.withLock { $0 }
        var claude = [homes.claude], codex = [homes.codex]
        for profile in settings[SettingKeys.accounts] {
            guard let dir = profile["dir"]?.string else { continue }
            if profile["agent"]?.string == Session.claudeAgent {
                claude.append(URL(fileURLWithPath: dir).appendingPathComponent("projects"))
            }
            if profile["agent"]?.string == Session.codexAgent {
                codex.append(URL(fileURLWithPath: dir).appendingPathComponent("sessions"))
            }
        }
        return (claude, codex)
    }

    /// Where a Claude Code session writes its conversation: what its hooks said, else the id Kelp started or resumed it
    /// with (a woken or restarted session has sent no hook yet, but its conversation is already there).
    func transcript(of ls: LiveSession) -> URL? {
        ls.transcriptPath.map { URL(fileURLWithPath: $0) } ?? transcript(of: ls.snapshot)
    }
    func transcript(of session: Session) -> URL? {
        let argv = session.argv
        guard session.agent == Session.claudeAgent,
            let flagIndex = argv.lastIndex(where: { $0 == "--session-id" || $0 == "--resume" }),
            flagIndex + 1 < argv.count
        else { return nil }
        return roots().claude.map {
            ClaudeHistory.folder(cwd: session.cwd, root: $0).appendingPathComponent(argv[flagIndex + 1] + ".jsonl")
        }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What the session's last turn ended with, if the agent keeps that somewhere Kelp can read.
    func lastReply(of ls: LiveSession) -> String? {
        let session = ls.snapshot
        if let remote = remotes.of(session.cwd) {
            return remoteTail(of: session, on: remote).flatMap(ClaudeHistory.lastReply(tail:))
        }
        guard session.agent == Session.codexAgent else {
            return transcript(of: ls).flatMap(ClaudeHistory.lastReply(transcript:))
        }
        if let open = Self.openRollout(pid: session.pid) { return CodexHistory.lastReply(rollout: open) }
        return roots().codex.lazy.compactMap {
            CodexHistory.lastReply(cwd: session.cwd, since: session.createdAt, root: $0)
        }
        .first
    }

    /// The last turns of a Claude Code or Codex conversation, for someone away from the terminal (the phone's page).
    /// None for other agents, or before the conversation exists. It waits on the disk, `lsof` or a host, so it runs off
    /// the caller's thread.
    func turns(of session: Session, live: LiveSession?) -> [ConversationTurns.Turn] {
        guard [Session.claudeAgent, Session.codexAgent].contains(session.agent) else { return [] }
        if let remote = remotes.of(session.cwd) {
            return remoteTail(of: session, on: remote).map { ConversationTurns.last(inTail: $0) } ?? []
        }
        return conversationFile(of: session, live: live).map { ConversationTurns.last(in: $0) } ?? []
    }

    /// How much of a conversation's end is read from a host: enough for its last turns, quick over ssh.
    static let remoteTailBytes = 1 << 20

    /// The last bytes of the conversation that a Claude Code in a remote project keeps on its host, in
    /// `~/.claude/projects/<its folder, as Claude Code names it>/`. It reads the file the agent's argv names
    /// (`--session-id`, `--resume`), or, for an agent started before it was given an id, the newest file there. It only
    /// uses a connection that is already open (`RemoteHost.connection`): a phone's poll or a notification never dials a
    /// host. It returns nil with no open connection, when there is no file yet, and for Codex.
    /// Limit: Codex on a host isn't read (its rollout is found through this Mac's `lsof` and `~/.codex/sessions`), and
    /// without an id, two agents in one folder read each other's conversation.
    func remoteTail(of session: Session, on remote: RemoteHost) -> Data? {
        remoteConversation(of: session, on: remote, read: "tail -c \(Self.remoteTailBytes)")
    }

    /// Runs `read` on the host (sh, reading the conversation's file on its stdin) and returns what it prints.
    func remoteConversation(of session: Session, on remote: RemoteHost, read: String) -> Data? {
        guard session.agent == Session.claudeAgent, remote.connection != nil else { return nil }
        let argv = session.argv
        let id = argv.lastIndex { $0 == "--session-id" || $0 == "--resume" }.flatMap { index in
            index + 1 < argv.count ? argv[index + 1] : nil
        }
        let out = Log.session.attempt("reading \(remote.host)'s conversation") {
            try remote.run(
                Self.remoteTailScript(path: remote.path, id: id, claude: hostClaude.withLock { $0 }, read: read),
                timeLimit: 10)
        }
        return out.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Copies the end of a remote Claude Code's conversation (its last `bytes`, over the open connection) into a file
    /// here that transcript readers can read, the newest for each session. Returns nil without a connection or a
    /// conversation there.
    func hostTail(of session: Session, bytes: Int) -> URL? {
        guard let remote = remotes.of(session.cwd),
            let tail = remoteConversation(of: session, on: remote, read: "tail -c \(bytes)")
        else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-host-transcripts")
        let file = dir.appendingPathComponent(session.id + ".jsonl")
        return Log.session.attempt("keeping \(session.id)'s conversation from its host") {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try tail.write(to: file, options: .atomic)
            return file
        }
    }

    /// Whether Claude Code's conversation `id` is surely not on `remote`'s host. It asks over ssh, which connects if it
    /// must (a wake or a restart does anyway). Returns false when that can't be told.
    func hostLacks(_ id: String, on remote: RemoteHost) -> Bool {
        let script = Self.remoteTailScript(
            path: remote.path, id: id, claude: hostClaude.withLock { $0 }, read: "head -c 1")
        do { return try remote.run(script, timeLimit: 15).isEmpty } catch { return false }
    }

    /// A script for sh on the host. It resolves the folder as the host does (a leading ~, a symlink), names it as
    /// Claude Code names it (each character that isn't a letter or a digit is "-"), then prints the file's end (or what
    /// `read` prints of it).
    static func remoteTailScript(
        path: String, id: String?, claude: String, read: String = "tail -c \(remoteTailBytes)"
    ) -> String {
        let named = id.flatMap { $0.wholeMatch(of: /[A-Za-z0-9-]+/) == nil ? nil : $0 }
        let file =
            named.map { #"f="$d/"# + $0 + #".jsonl""# }
            ?? #"f=$(ls -t "$d"/*.jsonl 2>/dev/null | head -n 1)"#
        return [
            "cd \(RemoteHost.cdArg(path)) || exit 0",
            "d=\(claude)/projects/\"$(pwd -P | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')\"",
            file, #"[ -n "$f" ] && [ -f "$f" ] && <"$f" "# + read, "exit 0"
        ].joined(separator: "\n")
    }

    /// The conversation a running Codex has open, which is the one thing that tells whose it is when two work in a
    /// folder. The program behind Codex's node wrapper holds the file open, so every process in its group is checked.
    private static func openRollout(pid: Int32) -> URL? {
        func lines(_ argv: [String]) -> [Substring] {
            let out = Log.session.attempt("asking \(argv[0])") {
                try Subprocess.run(argv, cwd: "/", env: [:], timeLimit: 5)
            }
            return String(decoding: out?.stdout ?? Data(), as: UTF8.self).split(whereSeparator: \.isNewline)
        }
        let group = lines(["/usr/bin/pgrep", "-g", String(pid)]).joined(separator: ",")
        guard !group.isEmpty else { return nil }
        return lines(["/usr/sbin/lsof", "-nP", "-Fn", "-p", group])
            .first { $0.hasPrefix("n") && $0.contains("/rollout-") && $0.hasSuffix(".jsonl") }.map {
                URL(fileURLWithPath: String($0.dropFirst()))
            }
    }

    /// The file `session`'s agent keeps its conversation in, for the agents whose files Kelp can tell apart: Claude Code,
    /// Codex (the rollout it has open, else the newest begun here since it started), pi and oh-my-pi (the one a hand-off
    /// opened it with, else the newest written here since it started).
    func conversationFile(of session: Session, live: LiveSession?) -> URL? {
        switch session.agent {
        case Session.claudeAgent: return live.flatMap(transcript(of:)) ?? transcript(of: session)
        case Session.codexAgent:
            if live != nil, let open = Self.openRollout(pid: session.pid) { return open }
            return roots().codex.lazy.compactMap {
                CodexHistory.rollouts(cwd: session.cwd, since: session.createdAt, root: $0).first
            }
            .first
        case let agent?:
            let argv = session.argv
            if let flag = argv.firstIndex(where: { $0 == "--session" || $0 == "--resume" }), flag + 1 < argv.count,
                argv[flag + 1].hasSuffix(".jsonl")
            {
                return URL(fileURLWithPath: argv[flag + 1])
            }
            let root = UsageFormat(rawValue: agent).flatMap(\.defaultRoot)
            // A pinned session (pi's `--session-id`, or `--session <id>` after a wake) uses that file, not the folder's
            // latest.
            if let root, let flag = argv.lastIndex(where: { $0 == "--session-id" || $0 == "--session" }),
                flag + 1 < argv.count, let file = PiHistory.file(id: argv[flag + 1], root: root)
            {
                return file
            }
            return root.flatMap { PiHistory.newest(cwd: session.cwd, since: session.createdAt, root: $0) }
        case nil: return nil
        }
    }

    /// The Codex thread a Claude Code transcript becomes, imported by Codex itself (its app server's
    /// `externalAgentConfig/import`, what its /import does): the whole conversation, tool calls included. A transcript
    /// imported before and unchanged since isn't imported again; its thread is the one Codex's import ledger names.
    /// Returns nil when Codex can't import it (not installed, or a transcript outside ~/.claude/projects, which it
    /// doesn't look in).
    func codexThread(importing transcript: URL, cwd: String) -> String? {
        let item: [String: Any] = [
            "itemType": "SESSIONS", "description": "Kelp hand-off",
            "details": ["sessions": [["path": transcript.path, "cwd": cwd]]]
        ]
        guard let codex = Log.session.attempt("finding codex", { try LoginPath.resolve("codex") }),
            let params = Log.session.attempt(
                "writing the import", { try JSONSerialization.data(withJSONObject: ["migrationItems": [item]]) })
        else { return nil }
        let done = AgentUsage.askCodex(
            path: codex, method: "externalAgentConfig/import", params: String(bytes: params, encoding: .utf8),
            open: openProbes, within: 60, until: "externalAgentConfig/import/completed")
        let results = (done?["params"] as? [String: Any])?["itemTypeResults"] as? [[String: Any]] ?? []
        if let thread = results.lazy.flatMap({ $0["successes"] as? [[String: Any]] ?? [] }).first?["target"] as? String
        {
            return thread
        }
        guard done?["params"] != nil, results.allSatisfy({ ($0["failures"] as? [Any] ?? []).isEmpty }) else {
            Log.session.error("Codex didn't import \(transcript.path): \(done.map { "\($0)" } ?? "no answer in 60 s")")
            return nil
        }
        let home = homes.withLock { $0.codex }.deletingLastPathComponent()
        return Self.importedThread(
            of: transcript, ledger: home.appendingPathComponent("external_agent_session_imports.json"))
    }

    /// The thread Codex's import ledger says `transcript` became.
    static func importedThread(of transcript: URL, ledger: URL) -> String? {
        let object = Log.session.attempt("reading Codex's import ledger") {
            try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as? [String: Any]
        }
        let real = transcript.resolvingSymlinksInPath().path
        return (object??["records"] as? [[String: Any]] ?? []).last {
            ($0["source_path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == real
        }?["imported_thread_id"] as? String
    }
}
