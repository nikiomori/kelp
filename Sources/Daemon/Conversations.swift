import AgentData
import Agents
import Core
import Foundation
import os

/// Where each session's agent keeps its conversation, and what reads it: the transcript of a Claude Code session, the
/// rollout a Codex has open, a pi's session file, the last reply of any of them, and the Codex thread a Claude Code
/// transcript becomes. What's in the files is AgentData's to read; this knows which file is whose.
final class Conversations: Sendable {
    let settings: SettingsStore
    /// The usage probes running now (`AgentUsage`'s): Codex's import runs as one, so the daemon's end ends it too.
    let openProbes: OpenProbes
    /// Where Claude Code and Codex keep their conversations, before the account profiles' (tests set it before the first call).
    let homes = OSAllocatedUnfairLock(
        initialState: (claude: ClaudeHistory.defaultRoot, codex: CodexHistory.defaultRoot))

    init(settings: SettingsStore, openProbes: OpenProbes) {
        self.settings = settings
        self.openProbes = openProbes
    }

    /// Default roots plus each account profile's config dir.
    func roots() -> (claude: [URL], codex: [URL]) {
        let homes = homes.withLock { $0 }
        var claude = [homes.claude], codex = [homes.codex]
        for profile in settings[SettingKeys.accounts] {
            guard let dir = profile["dir"]?.string else { continue }
            if profile["agent"]?.string == "claude" {
                claude.append(URL(fileURLWithPath: dir).appendingPathComponent("projects"))
            }
            if profile["agent"]?.string == "codex" {
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
        guard session.agent == "claude",
            let flagIndex = argv.lastIndex(where: { $0 == "--session-id" || $0 == "--resume" }),
            flagIndex + 1 < argv.count
        else { return nil }
        return roots().claude.map {
            ClaudeHistory.folder(cwd: session.cwd, root: $0).appendingPathComponent(argv[flagIndex + 1] + ".jsonl")
        }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What its last turn ended with, if the agent keeps that somewhere Kelp can read.
    func lastReply(of ls: LiveSession) -> String? {
        let session = ls.snapshot
        guard session.agent == "codex" else { return transcript(of: ls).flatMap(ClaudeHistory.lastReply(transcript:)) }
        if let open = Self.openRollout(pid: session.pid) { return CodexHistory.lastReply(rollout: open) }
        return roots().codex.lazy.compactMap {
            CodexHistory.lastReply(cwd: session.cwd, since: session.createdAt, root: $0)
        }
        .first
    }

    /// The conversation a running Codex has open, the one thing that says whose it is when two work in a folder. The program
    /// behind its node wrapper holds it: another process of its group.
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
        case "claude": return live.flatMap(transcript(of:)) ?? transcript(of: session)
        case "codex":
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
            return UsageFormat(rawValue: agent).flatMap(\.defaultRoot).flatMap {
                PiHistory.newest(cwd: session.cwd, since: session.createdAt, root: $0)
            }
        case nil: return nil
        }
    }

    /// The Codex thread a Claude Code transcript becomes, imported by Codex itself (its app server's
    /// `externalAgentConfig/import`, what its /import does): the whole conversation, tool calls included. One imported
    /// before and unchanged since isn't imported again: its thread is the one Codex's import ledger names. Nil when Codex
    /// can't (not installed, or a transcript outside ~/.claude/projects, which it doesn't look in).
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
