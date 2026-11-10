import AgentData
import Core
import Foundation

// What an agent's transcript says: its context window and what fills it, its subagents' steps.

extension SessionContextWindow: Handled {
    func handle(_ sessions: Sessions) throws -> Usage? {
        guard let transcript = sessions.existing(id).flatMap(sessions.agentUsage.conversations.transcript(of:)),
            let context = ClaudeContext.usage(transcript: transcript)
        else { return nil }
        return Usage(
            used: context.used, window: sessions.agentUsage.contextWindow(model: context.model, peak: context.peak),
            cacheUntil: context.cacheUntil)
    }
}

extension SessionContextParts: Handled {
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
    func handle(_ sessions: Sessions) throws -> Result {
        guard let ls = sessions.existing(id), let parent = sessions.agentUsage.conversations.transcript(of: ls) else {
            return [:]
        }
        var last: Result = [:]
        for run in ls.snapshot.runningSubagents {
            guard let file = SubagentTranscript.file(parent: parent, id: run.id),
                let tail = Data(tail: 262_144, of: file),
                let step = SubagentTranscript.lastStep(tail: tail),
                let touched = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            last[run.id] = Last(step: step, touched: touched)
        }
        return last
    }
}

extension SessionSubagentJournal: Handled {
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
