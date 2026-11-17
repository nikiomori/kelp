import Core
import Foundation
import os

/// Asks a fork of a Claude Code agent's conversation (`--fork-session`) for one line on what it did and what's left. It
/// is asked while the cache is warm, and the conversation itself is left as it was. The fork runs without Kelp's hooks
/// or KELP_SESSION, so nothing of it reaches this session's status.
/// Limit: the fork's own transcript stays in Claude Code's history (Kelp doesn't write in ~/.claude).
extension SessionRecap: AsyncHandled {
    static let agents = AgentAccess.acts
    static let prompt =
        "In one line of at most 20 words: what did you just do, and what is left for me? No preamble, no markdown."

    /// The fork gets no tools, because it only says what happened. Nobody watches it, so a conversation steered by a
    /// page it read mustn't get a turn that acts.
    static func arguments(_ claude: String, conversation: String) -> [String] {
        // No MCP tools either, and the fork leaves no conversation of its own in ~/.claude.
        // Nor hooks: a project's settings may have changed since its session began, and nobody is there to see them run.
        [
            claude, "-p", prompt, "--resume", conversation, "--fork-session", "--tools", "", "--strict-mcp-config",
            "--no-session-persistence",
            "--settings", #"{"disableAllHooks":true}"#
        ]
    }

    /// Which of `folders` the transcript at `path` belongs to. Claude Code names a project's folder after its path,
    /// with every character but letters and digits turned into "-".
    static func folder(of path: String, among folders: [String]) -> String? {
        let project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return folders.first {
            $0.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression) == project
        }
    }

    func handle(_ sessions: Sessions) async throws -> String? {
        // Only a Claude Code conversation can be forked to go on from (`AgentManifest.Transcript.claude`). On a host
        // the fork runs there, in the project's folder, on the conversation the session's id names (its hooks there
        // give no path).
        guard let ls = sessions.existing(id), let manifest = sessions.setup.agent(ls.snapshot.agent),
            manifest.transcript == .claude
        else { return nil }
        let rec = ls.snapshot, remote = sessions.remotes.of(rec.cwd)
        let pinned = rec.argv.lastIndex { $0 == "--session-id" || $0 == "--resume" }.flatMap {
            $0 + 1 < rec.argv.count ? rec.argv[$0 + 1] : nil
        }
        guard let transcript = remote == nil ? ls.transcriptPath : pinned.map({ $0 + ".jsonl" }) else { return nil }
        guard sessions.recaps.withLock({ $0.insert(id).inserted }) else { return nil }
        defer { _ = sessions.recaps.withLock { $0.remove(id) } }
        // Claude Code finds a conversation by the folder it began in, which its transcript's folder names.
        let cwd = Self.folder(of: transcript, among: [rec.cwd, ls.turnDir].compactMap { $0 }) ?? rec.cwd
        guard remote != nil || sessions.remotes.of(cwd) == nil else { return nil }
        let conversation = ((transcript as NSString).lastPathComponent as NSString).deletingPathExtension
        // The fork runs neither as a child of this session (KELP_*) nor of a Claude Code that started kelpd (its marker
        // turns the transcript off).
        var env = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("KELP_") && $0.key != "CLAUDE_CODE_CHILD_SESSION"
        }
        if let name = rec.profile, let profile = sessions.setup.profile(name, agent: manifest.id) {
            env[profile.key] = profile.dir
        }   // its own account
        let out: Subprocess.Output
        if let remote {
            let run = remote.command(Self.arguments(manifest.command, conversation: conversation))
            let argv = [remote.ssh] + remote.sshArgs(tty: false) + ["sh -c " + ShellQuote.word(run)]
            out = try await sessions.offloads.run { [env] in
                var env = env
                env["PATH"] = Sessions.childPath   // read here, in the slot, since the first read runs the login shell
                return try Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, stdin: Data(), timeLimit: 90)
            }
        } else {
            let command = manifest.command
            out = try await sessions.offloads.run { [env] in
                // PATH is read in the slot here too, because the login PATH's first read runs the login shell.
                var env = env
                env["PATH"] = Sessions.childPath
                let argv = Self.arguments(try LoginPath.resolve(command), conversation: conversation)
                // stdin is given, because otherwise -p waits 3 s for it
                return try Subprocess.run(argv, cwd: cwd, env: env, stdin: Data(), timeLimit: 90)
            }
        }
        let line =
            String(decoding: out.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard out.status == 0, !out.timedOut, !line.isEmpty else { return nil }
        let short = line.count > 160 ? String(line.prefix(159)) + "…" : line
        // The line isn't saved over a turn begun in the meantime (this line is about the turn before it), nor over a
        // later turn that ended meanwhile (its own line is newer).
        guard
            ls.update({ if $0.status == .done && $0.statusAt == rec.statusAt { $0.summary = short } }).summary == short
        else { return nil }
        sessions.publish(ls)
        return short
    }
}

extension Methods {
    static let recapMethods: [any Answered.Type] = [SessionRecap.self]
}
