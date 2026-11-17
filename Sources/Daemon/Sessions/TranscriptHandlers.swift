import AgentData
import Core
import Foundation

// What an agent's transcript says: its context window and what fills it, its subagents' steps.

extension SessionContextWindow: Handled {
    static let agents = AgentAccess.reads
    func handle(_ sessions: Sessions) throws -> Usage? {
        // A remote one's: the end of its conversation on the host, where its last turn's usage is.
        let conversations = sessions.agentUsage.conversations, ls = sessions.existing(id)
        guard
            let transcript = ls.flatMap(conversations.transcript(of:))
                ?? ls.flatMap({ conversations.hostTail(of: $0.snapshot, bytes: Conversations.remoteTailBytes) }),
            let context = ClaudeContext.usage(transcript: transcript)
        else { return nil }
        return Usage(
            used: context.used, window: sessions.agentUsage.contextWindow(model: context.model, peak: context.peak),
            cacheUntil: context.cacheUntil)
    }
}

extension SessionContextParts: Handled {
    static let agents = AgentAccess.reads
    func handle(_ sessions: Sessions) throws -> Parts? {
        guard let ls = sessions.existing(id), let transcript = sessions.agentUsage.conversations.transcript(of: ls),
            let context = ClaudeContext.usage(transcript: transcript),
            var parts = ClaudeContext.parts(
                try Data(contentsOf: transcript, options: .mappedIfSafe), used: context.used)
        else { return nil }
        parts.setup = sessions.setup.claudeSetup(ls.snapshot).map { ClaudeContext.fit($0, to: parts.base) }
        return parts
    }
}

extension SessionSubagentSteps: Handled {
    static let agents = AgentAccess.reads
    func handle(_ sessions: Sessions) throws -> Result {
        guard let ls = sessions.existing(id), let parent = sessions.agentUsage.conversations.transcript(of: ls) else {
            return [:]
        }
        var last: Result = [:]
        for run in ls.snapshot.runningSubagents {
            guard let file = SubagentTranscript.file(parent: parent, id: run.id),
                let step = sessions.agentUsage.subagentTails.value(file.path, { Self.last(file) })
            else { continue }
            last[run.id] = step
        }
        return last
    }

    private static func last(_ file: URL) -> Last? {
        guard let tail = Data(tail: 262_144, of: file), let step = SubagentTranscript.lastStep(tail: tail),
            let written = Artifacts.fileStat(file.path)?.mtime
        else { return nil }
        let touched = Date(timeIntervalSince1970: TimeInterval(written.tv_sec) + TimeInterval(written.tv_nsec) / 1e9)
        return Last(step: step, touched: touched)
    }
}

extension SessionSubagentJournal: Handled {
    static let agents = AgentAccess.reads
    func handle(_ sessions: Sessions) throws -> Result {
        let usage = sessions.agentUsage.conversations
        guard
            let parent = try sessions.existing(id).flatMap(usage.transcript(of:))
                ?? sessions.store.session(id).flatMap(usage.transcript(of:)),
            let file = SubagentTranscript.file(parent: parent, id: subagent),
            FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        return try SubagentTranscript.journal(file)
    }
}

extension Methods {
    static let transcriptMethods: [any Answered.Type] = [
        SessionContextWindow.self, SessionContextParts.self, SessionSubagentSteps.self, SessionSubagentJournal.self
    ]
}
