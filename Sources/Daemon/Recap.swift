import Core
import Foundation
import os

/// What a Claude Code agent did and what's left, in a line, from a fork of its conversation (`--fork-session`): asked
/// while its cache is warm, the conversation itself left as it was. The fork runs without Kelp's hooks or KELP_SESSION,
/// so nothing of it reaches this session's status. Limit: the fork's own transcript stays in Claude Code's history
/// (Kelp doesn't write in ~/.claude).
extension SessionRecap: AsyncHandled {
    static let prompt =
        "In one line of at most 20 words: what did you just do, and what is left for me? No preamble, no markdown."

    /// No tools: the fork only says what happened. Nobody watches it, so a conversation steered by a page it read
    /// mustn't get a turn that acts.
    static func arguments(_ claude: String, conversation: String) -> [String] {
        // No MCP tools either, and the fork leaves no conversation of its own in ~/.claude.
        // Nor hooks: a project's settings may have changed since its session began, and nobody is there to see them run.
        [
            claude, "-p", prompt, "--resume", conversation, "--fork-session", "--tools", "", "--strict-mcp-config",
            "--no-session-persistence",
            "--settings", #"{"disableAllHooks":true}"#
        ]
    }

    /// Which of `folders` the transcript at `path` belongs to: Claude Code names a project's folder by its path, every
    /// character but letters and digits a "-".
    static func folder(of path: String, among folders: [String]) -> String? {
        let project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return folders.first {
            $0.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression) == project
        }
    }

    func handle(_ sessions: Sessions) async throws -> String? {
        guard let ls = sessions.existing(id), ls.snapshot.agent == "claude", let transcript = ls.transcriptPath else {
            return nil
        }
        guard sessions.recaps.withLock({ $0.insert(id).inserted }) else { return nil }
        defer { _ = sessions.recaps.withLock { $0.remove(id) } }
        // Claude Code finds a conversation by the folder it began in, which its transcript's folder names.
        let rec = ls.snapshot,
            cwd = Self.folder(of: transcript, among: [rec.cwd, ls.turnDir].compactMap { $0 }) ?? rec.cwd
        guard sessions.remotes.of(cwd) == nil else { return nil }
        let conversation = ((transcript as NSString).lastPathComponent as NSString).deletingPathExtension
        // Not as a child of this session (KELP_*), nor of a Claude Code that started kelpd (its marker turns the transcript off).
        var env = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("KELP_") && $0.key != "CLAUDE_CODE_CHILD_SESSION"
        }
        env["PATH"] = Sessions.childPath
        if let name = rec.profile, let profile = sessions.setup.profile(name, agent: "claude") {
            env[profile.key] = profile.dir
        }   // its own account
        let claude = try LoginPath.resolve("claude")
        let out = try await Subprocess.run(
            Self.arguments(claude, conversation: conversation), cwd: cwd, env: env,
            stdin: Data(), timeLimit: 90)   // -p waits 3 s for stdin otherwise
        let line =
            String(decoding: out.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard out.status == 0, !out.timedOut, !line.isEmpty else { return nil }
        let short = line.count > 160 ? String(line.prefix(159)) + "…" : line
        // A turn begun in the meantime keeps its own line: this one is about the turn before it.
        // Nor does a later turn that ended meanwhile: its own line is newer.
        guard
            ls.update({ if $0.status == .done && $0.statusAt == rec.statusAt { $0.summary = short } }).summary == short
        else { return nil }
        sessions.publish(ls)
        return short
    }
}
