import AgentData
import Agents
import Core
import Foundation
import os

extension SessionSetup {
    /// argv that brings back this session's own conversation. A remote one's is on its host: resumed by its id once it's
    /// there.
    func resumeArgv(_ rec: Session, _ manifest: AgentManifest) -> [String] {
        // pi and Grok, pinned: resumed by its id once it wrote its conversation; before its first message it has none
        // (resuming one would stop it at "No session found"), so it starts under the same id. On a host: pi's
        // `--session-id` resumes one that's there and starts one that isn't.
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
        // On a host, pinned with nothing typed yet: no conversation there to resume ("No conversation found"), so it
        // starts under the same id.
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
            // Nothing was typed in the session this forks (`HomeSeed`): no conversation to copy, a new one of its own.
            if rec.argv.contains("--fork-session"), let id = rec.argv.dropFirst(index + 1).first,
                ClaudeHistory.session(id: id, cwd: rec.cwd, root: claudeProjects(rec)) == nil
            {
                return manifest.following(rec.argv, conversation: UUID().uuidString.lowercased())
            }
            return rec.argv
        }
        if let index = rec.argv.firstIndex(of: pin), index + 1 < rec.argv.count {
            // Pinned but nothing typed yet: no conversation to resume, start it under the same id.
            return ClaudeHistory.session(id: rec.argv[index + 1], cwd: rec.cwd, root: claudeProjects(rec)) != nil
                ? manifest.resuming(rec.argv) : rec.argv
        }
        let conversations = ClaudeHistory.sessions(cwd: rec.cwd, root: claudeProjects(rec))
        // From before ids were pinned (or restarted with "latest in this folder", which hands it another agent's
        // conversation): the first conversation that started here between this session and the next one, unless another
        // session has it; none → start fresh. Limit: misses prompts typed out of order across sessions.
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
