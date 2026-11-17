import Core
import Foundation

/// Reads what Claude Code keeps of a subagent beside its parent's conversation:
/// `<conversation>/subagents/agent-<id>.jsonl`, and a `.meta.json` with the subagent's kind and task. Thinking and what
/// tools printed are left out, because the steps and the final report say enough.
public enum SubagentTranscript {
    /// Returns the subagent's transcript, found from the parent's transcript or from a sibling subagent's transcript,
    /// because a hook sent from inside a subagent names that subagent. The id comes from a tab's URI, so nothing in it
    /// may lead out of the folder.
    public static func file(parent: URL, id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let folder = parent.deletingLastPathComponent()
        let subagents =
            folder.lastPathComponent == "subagents"
            ? folder : parent.deletingPathExtension().appendingPathComponent("subagents")
        return subagents.appendingPathComponent("agent-\(id).jsonl")
    }

    /// Returns the last tool the subagent called, read from the end of its transcript.
    public static func lastStep(tail: Data) -> SubagentStep? {
        for line in JSONL.lines(tail).reversed() {
            if let step = assistant(line)?.steps.last { return step }
        }
        return nil
    }

    /// Reads the whole transcript. The file is memory-mapped, not read, because a long transcript runs to tens of
    /// megabytes, and most of its lines are skipped without being parsed.
    public static func journal(_ url: URL) throws -> SessionSubagentJournal.Journal {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let meta = FileManager.default.contents(
            atPath: url.deletingPathExtension().appendingPathExtension("meta.json").path
        ).flatMap(JSONL.object)
        var journal = SessionSubagentJournal.Journal(
            kind: meta?["agentType"] as? String ?? "", task: meta?["description"] as? String)
        var lastText: String?
        for line in JSONL.lines(data) {
            guard let reply = assistant(line) else { continue }
            journal.steps += reply.steps
            journal.model = reply.model ?? journal.model
            journal.context = reply.context ?? journal.context
            journal.report = reply.report ?? journal.report
            lastText = reply.text ?? lastText
        }
        journal.report = journal.report ?? lastText
        return journal
    }

    private struct Assistant {
        var steps: [SubagentStep] = [], model: String?, context: Int?, report: String?, text: String?
    }

    private static let marker = Data(#""type":"assistant""#.utf8)

    private static func assistant(_ line: Data) -> Assistant? {
        guard line.range(of: marker) != nil, let object = JSONL.object(line),
            object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { return nil }
        var reply = Assistant(model: message["model"] as? String)
        if let usage = message["usage"] as? [String: Any] {
            reply.context = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) {
                $0 + (usage[$1] as? Int ?? 0)
            }
        }
        let at = JSONL.date(object["timestamp"]) ?? .distantPast
        for block in content {
            if block["type"] as? String == "text", let text = block["text"] as? String { reply.text = text }
            guard block["type"] as? String == "tool_use", let tool = block["name"] as? String else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            if tool == "SubagentHandback" {
                reply.report = input["message"] as? String
                continue
            }
            reply.steps.append(SubagentStep(tool: tool, detail: detail(input, cwd: object["cwd"] as? String), at: at))
        }
        return reply
    }

    /// Returns the one detail that says what a call did: its path, the command's first line, or what it looked for.
    private static func detail(_ input: [String: Any], cwd: String?) -> String {
        let value =
            ["file_path", "path", "command", "pattern", "url", "query", "description", "prompt"].lazy.compactMap {
                input[$0] as? String
            }.first ?? ""
        let line = value.split(separator: "\n").first.map(String.init) ?? ""
        return cwd.map { line.replacingOccurrences(of: $0 + "/", with: "") } ?? line
    }
}
