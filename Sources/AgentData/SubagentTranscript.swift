import Core
import Foundation

/// What Claude Code keeps of a subagent, beside its parent's conversation: `<conversation>/subagents/agent-<id>.jsonl`, and
/// `.meta.json` with its kind and task. Thinking and what tools printed stay out: the steps and the final report say enough.
public enum SubagentTranscript {
    /// Its transcript, from the parent's, or a sibling's: a hook sent from inside a subagent names that one. An id comes
    /// from a tab's URI, so nothing in it leaves the folder.
    public static func file(parent: URL, id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let folder = parent.deletingLastPathComponent()
        let subagents =
            folder.lastPathComponent == "subagents"
            ? folder : parent.deletingPathExtension().appendingPathComponent("subagents")
        return subagents.appendingPathComponent("agent-\(id).jsonl")
    }

    /// The last tool it called, from the end of its transcript.
    public static func lastStep(tail: Data) -> SubagentStep? {
        for line in JSONL.lines(tail).reversed() {
            if let step = assistant(line)?.steps.last { return step }
        }
        return nil
    }

    /// All of it. Mapped, not read: a long one runs to tens of megabytes, most of it lines this skips unparsed.
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

    /// The one thing that says what a call was: its path, the command's first line, what it looked for.
    private static func detail(_ input: [String: Any], cwd: String?) -> String {
        let value =
            ["file_path", "path", "command", "pattern", "url", "query", "description", "prompt"].lazy.compactMap {
                input[$0] as? String
            }.first ?? ""
        let line = value.split(separator: "\n").first.map(String.init) ?? ""
        return cwd.map { line.replacingOccurrences(of: $0 + "/", with: "") } ?? line
    }
}
