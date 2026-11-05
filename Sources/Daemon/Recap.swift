import Foundation
import os
import Core

/// What a Claude Code agent did and what's left, in a line, from a fork of its conversation (`--fork-session`): asked
/// while its cache is warm, the conversation itself left as it was. The fork runs without Kelp's hooks or KELP_SESSION,
/// so nothing of it reaches this session's status. Limit: the fork's own transcript stays in Claude Code's history
/// (Kelp doesn't write in ~/.claude).
extension SessionRecap: AsyncHandled {
    static let prompt = "In one line of at most 20 words: what did you just do, and what is left for me? No preamble, no markdown."

    /// Sessions with a recap running: one at a time each, however many turns end meanwhile.
    static let running = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// No tools: the fork only says what happened. Nobody watches it, so a conversation steered by a page it read
    /// mustn't get a turn that acts.
    static func arguments(_ claude: String, conversation: String) -> [String] {
        [claude, "-p", prompt, "--resume", conversation, "--fork-session", "--tools", ""]
    }

    func handle(_ sessions: Sessions) async throws -> String? {
        guard let ls = sessions.existing(id), ls.snapshot.agent == "claude", let transcript = ls.transcriptPath else { return nil }
        guard Self.running.withLock({ $0.insert(id).inserted }) else { return nil }
        defer { _ = Self.running.withLock { $0.remove(id) } }
        let rec = ls.snapshot, cwd = ls.turnDir ?? rec.cwd
        guard sessions.remotes.of(cwd) == nil else { return nil }
        let conversation = ((transcript as NSString).lastPathComponent as NSString).deletingPathExtension
        // Not as a child of this session (KELP_*), nor of a Claude Code that started kelpd (its marker turns the transcript off).
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("KELP_") && $0.key != "CLAUDE_CODE_CHILD_SESSION" }
        env["PATH"] = Sessions.childPath
        if let name = rec.profile, let p = sessions.profile(name, agent: "claude") { env[p.key] = p.dir }   // its own account
        let claude = try LoginPath.resolve("claude")
        let out = try await Subprocess.run(Self.arguments(claude, conversation: conversation), cwd: cwd, env: env,
                                           stdin: Data(), timeLimit: 90)   // -p waits 3 s for stdin otherwise
        let line = String(decoding: out.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard out.status == 0, !out.timedOut, !line.isEmpty else { return nil }
        let short = line.count > 160 ? String(line.prefix(159)) + "…" : line
        // A turn begun in the meantime keeps its own line: this one is about the turn before it.
        guard ls.update({ if $0.status == .done { $0.summary = short } }).summary == short else { return nil }
        sessions.publish(ls)
        return short
    }
}
