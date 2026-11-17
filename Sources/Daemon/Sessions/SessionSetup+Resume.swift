import AgentData
import Agents
import Core
import Foundation
import os

extension SessionSetup {
    /// The argv that brings back this session's own conversation. A remote session's conversation is on its host, and
    /// is resumed by its id once it is there.
    func resumeArgv(_ rec: Session, _ manifest: AgentManifest) -> [String] {
        // pi and Grok with a pinned id are resumed by that id once they wrote their conversation. Before the first
        // message there is none (resuming would stop at "No session found"), so the agent starts under the same id. On
        // a host, pi's `--session-id` resumes a conversation that's there and starts one that isn't.
        if ["pi", "grok"].contains(rec.agent), let pin = manifest.sessionIdFlag,
            let index = rec.argv.firstIndex(of: pin), index + 1 < rec.argv.count
        {
            let id = rec.argv[index + 1], root = UsageFormat(rawValue: rec.agent ?? "")?.defaultRoot
            let written =
                remotes.of(rec.cwd) == nil
                && root.map {
                    rec.agent == "pi" ? PiHistory.file(id: id, root: $0) != nil : PiHistory.grokHas(id: id, root: $0)
                }
                    == true
            return written ? manifest.resuming(rec.argv) : rec.argv
        }
        // On a host, a pinned session with nothing typed yet has no conversation there to resume ("No conversation
        // found"), so it starts under the same id.
        if rec.agent == Session.claudeAgent, let remote = remotes.of(rec.cwd), let pin = manifest.sessionIdFlag,
            let index = rec.argv.firstIndex(of: pin), index + 1 < rec.argv.count,
            agentUsage.conversations.hostLacks(rec.argv[index + 1], on: remote)
        {
            return rec.argv
        }
        guard rec.agent == Session.claudeAgent, remotes.of(rec.cwd) == nil, let flag = manifest.resumeIdFlag,
            let pin = manifest.sessionIdFlag
        else { return manifest.resuming(rec.argv) }
        if let index = rec.argv.firstIndex(of: flag) {
            // When nothing was typed in the session this forks (`HomeSeed`), there's no conversation to copy, so it
            // starts a new one of its own.
            if rec.argv.contains("--fork-session"), let id = rec.argv.dropFirst(index + 1).first,
                ClaudeHistory.session(id: id, cwd: rec.cwd, root: claudeProjects(rec)) == nil
            {
                return manifest.following(rec.argv, conversation: UUID().uuidString.lowercased())
            }
            return rec.argv
        }
        if let index = rec.argv.firstIndex(of: pin), index + 1 < rec.argv.count {
            // Pinned but nothing typed yet: there's no conversation to resume, so start it under the same id.
            return ClaudeHistory.session(id: rec.argv[index + 1], cwd: rec.cwd, root: claudeProjects(rec)) != nil
                ? manifest.resuming(rec.argv) : rec.argv
        }
        let conversations = ClaudeHistory.sessions(cwd: rec.cwd, root: claudeProjects(rec))
        // For a session from before ids were pinned (or restarted with "latest in this folder", which hands it another
        // agent's conversation), take the first conversation that started here between this session and the next one,
        // unless another session has it. With none, start fresh. Limit: misses prompts typed out of order across
        // sessions.
        let base = rec.argv.filter { !manifest.resumeArgs.contains($0) }
        let all = store.look("the sessions") { try $0.sessions() } ?? []
        let claimed = Set(
            all.filter { $0.id != rec.id }.flatMap { other in
                other.argv.indices.dropLast().filter { [pin, flag].contains(other.argv[$0]) }.map {
                    other.argv[$0 + 1].lowercased()
                }
            })
        let next =
            all.filter { $0.agent == Session.claudeAgent && $0.cwd == rec.cwd && $0.createdAt > rec.createdAt }.map(
                \.createdAt
            )
            .min() ?? .distantFuture
        let own =
            conversations
            .filter {
                $0.started >= rec.createdAt.addingTimeInterval(-2) && $0.started < next
                    && !claimed.contains($0.id.lowercased())
            }
            .min { $0.started < $1.started }
        return own.map { base + [flag, $0.id] } ?? base
    }
}
