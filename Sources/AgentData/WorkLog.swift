import Core
import Foundation

/// The prompts and tool calls of one conversation file, read a piece at a time: Claude Code's transcript (or one of its
/// subagents'), or Codex's rollout. The caller hands it the bytes the file grew by, so a long transcript is read once.
/// What the tools printed is skipped; only whether a call failed, and an edit's line counts, are kept.
public struct WorkLog: Sendable {
    public struct Prompt: Sendable, Equatable {
        public var text: String, at: Date
    }

    /// A tool call, with the few arguments a map needs.
    public struct Call: Sendable, Equatable {
        public var id: String, tool: String, at: Date
        /// The folder the agent was in.
        public var cwd: String?
        public var path: String?, command: String?, url: String?, pattern: String?, query: String?
        /// A subagent's kind and task (Task, Agent).
        public var kind: String?, task: String?
        /// Codex's patch text.
        public var patch: String?
        public var failed = false, added = 0, removed = 0
        /// When its result came back.
        public var done: Date?
    }

    public private(set) var prompts: [Prompt] = []
    public private(set) var calls: [Call] = []
    /// The folder the conversation began in.
    public private(set) var cwd: String?
    /// Bytes read so far that ended in a whole line. The caller reads from here next time.
    public private(set) var offset: UInt64 = 0
    private var byId: [String: Int] = [:]
    private var lastAt = Date.distantPast

    public init() {}

    /// Reads the bytes that follow what was read before. A last line without its newline is left for next time.
    public mutating func read(_ data: Data) {
        guard let end = data.lastIndex(of: 10) else { return }
        offset += UInt64(end - data.startIndex + 1)
        for line in JSONL.lines(data[data.startIndex...end]) {
            guard let entry = JSONL.object(line) else { continue }
            let at = JSONL.date(entry["timestamp"]) ?? lastAt
            lastAt = at
            if cwd == nil { cwd = entry["cwd"] as? String }
            switch entry["type"] as? String {
            case "user": claudeUser(entry, at: at)
            case "assistant": claudeAssistant(entry, at: at)
            case "session_meta", "turn_context":
                if cwd == nil { cwd = (entry["payload"] as? [String: Any])?["cwd"] as? String }
            case "event_msg":
                if let payload = entry["payload"] as? [String: Any], payload["type"] as? String == "user_message",
                    let text = (payload["message"] as? String).flatMap(JSONL.typed)
                {
                    prompts.append(Prompt(text: String(text.prefix(500)), at: at))
                }
            case "response_item": codex(entry["payload"] as? [String: Any] ?? [:], at: at)
            default: break
            }
        }
    }

    // MARK: Claude Code

    private mutating func claudeUser(_ entry: [String: Any], at: Date) {
        guard entry["isMeta"] as? Bool != true, entry["isCompactSummary"] as? Bool != true,
            let message = entry["message"] as? [String: Any]
        else { return }
        let content = message["content"]
        let blocks = content as? [[String: Any]] ?? []
        let results = blocks.filter { $0["type"] as? String == "tool_result" }
        if results.isEmpty {
            if entry["isSidechain"] as? Bool != true, let text = JSONL.promptText(content) {
                prompts.append(Prompt(text: String(text.prefix(500)), at: at))
            }
            return
        }
        let detail = entry["toolUseResult"] as? [String: Any]
        for result in results {
            guard let id = result["tool_use_id"] as? String, let index = byId[id] else { continue }
            calls[index].done = at
            if result["is_error"] as? Bool == true || detail?["interrupted"] as? Bool == true {
                calls[index].failed = true
            }
            if results.count == 1, let detail { Self.count(detail, into: &calls[index]) }
        }
    }

    private mutating func claudeAssistant(_ entry: [String: Any], at: Date) {
        guard let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
        for block in content where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let tool = block["name"] as? String, byId[id] == nil else {
                continue
            }
            let input = block["input"] as? [String: Any] ?? [:]
            var call = Call(id: id, tool: tool, at: at, cwd: entry["cwd"] as? String ?? cwd)
            call.path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String
            call.command = input["command"] as? String
            call.url = input["url"] as? String
            call.pattern = input["pattern"] as? String
            call.query = (input["query"] ?? input["question"]) as? String
            call.kind = input["subagent_type"] as? String
            call.task = (input["description"] ?? input["prompt"]) as? String
            if tool == "AskUserQuestion", let first = (input["questions"] as? [[String: Any]])?.first {
                call.query = first["question"] as? String
            }
            add(call)
        }
    }

    /// An edit's lines from its result: a patch's + and − lines, or a new file's lines.
    private static func count(_ detail: [String: Any], into call: inout Call) {
        if let hunks = detail["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            for line in hunks.flatMap({ $0["lines"] as? [String] ?? [] }) {
                if line.hasPrefix("+") { call.added += 1 } else if line.hasPrefix("-") { call.removed += 1 }
            }
        } else if detail["type"] as? String == "create", let text = detail["content"] as? String {
            call.added = text.split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    // MARK: Codex

    private mutating func codex(_ payload: [String: Any], at: Date) {
        let type = payload["type"] as? String ?? ""
        switch type {
        case "function_call", "custom_tool_call", "local_shell_call":
            let id = payload["call_id"] as? String ?? payload["id"] as? String ?? UUID().uuidString
            let name = payload["name"] as? String ?? (type == "local_shell_call" ? "shell" : "tool")
            let raw = payload["arguments"] ?? payload["input"] ?? payload["action"]
            let args = (raw as? String).flatMap { JSONL.object(Data($0.utf8)) } ?? raw as? [String: Any] ?? [:]
            let folder = (args["workdir"] ?? args["working_directory"]) as? String
            var call = Call(id: id, tool: name, at: at, cwd: folder ?? cwd)
            let command = args["command"] ?? args["cmd"]
            call.command = (command as? [String]).map(Self.unwrapShell) ?? command as? String
            if name == "apply_patch" {
                // The JSON tool's patch is its `input`; the freeform tool's is the call's text itself.
                call.patch = args["input"] as? String ?? args["patch"] as? String ?? raw as? String
            } else if let argv = command as? [String], argv.first == "apply_patch", argv.count > 1 {
                // Older rollouts ran it through the shell: `["apply_patch", "<patch>"]`.
                call.tool = "apply_patch"
                call.patch = argv[1]
            }
            call.path = args["path"] as? String
            add(call)
        case "function_call_output", "custom_tool_call_output":
            guard let id = payload["call_id"] as? String, let index = byId[id] else { return }
            calls[index].done = at
            let output = payload["output"]
            let meta =
                ((output as? String).flatMap { JSONL.object(Data($0.utf8)) } ?? output as? [String: Any])?[
                    "metadata"] as? [String: Any]
            // Older rollouts give JSON with `metadata.exit_code`; newer ones plain text ending "Process exited with
            // code N".
            let text = output as? String
            let exited = text?.firstMatch(of: /Process exited with code (-?\d+)/)
            let plain = (exited ?? text?.firstMatch(of: /^Exit code: (-?\d+)/)).flatMap { Int($0.1) }
            if let code = meta?["exit_code"] as? Int ?? plain, code != 0 { calls[index].failed = true }
            if let patch = calls[index].patch { Self.count(patch: patch, into: &calls[index]) }
        case "web_search_call":
            var call = Call(id: payload["id"] as? String ?? UUID().uuidString, tool: "WebSearch", at: at, cwd: cwd)
            call.query = (payload["action"] as? [String: Any])?["query"] as? String
            add(call)
        default: break
        }
    }

    /// Codex runs `["bash", "-lc", "<script>"]`; the script is the command.
    private static func unwrapShell(_ argv: [String]) -> String {
        if argv.count == 3, ["bash", "sh", "zsh"].contains((argv[0] as NSString).lastPathComponent),
            argv[1].hasPrefix("-")
        {
            return argv[2]
        }
        return argv.joined(separator: " ")
    }

    private static func count(patch: String, into call: inout Call) {
        for line in patch.split(separator: "\n") {   // kept compact: `+` and `-` for each changed line
            if line.hasPrefix("+") { call.added += 1 } else if line.hasPrefix("-") { call.removed += 1 }
        }
    }

    /// Keeps a call as small as the map needs it, since a session's calls stay in memory while its map is shown: a
    /// command without its heredocs' text (`cat > f <<EOF` holds a whole file), a task's first words, a patch's file
    /// lines and one character of each changed line (what `WorkMap.patchFiles` counts).
    private mutating func add(_ call: Call) {
        var call = call
        if let command = call.command {
            call.command = String(ShellTouches.withoutHeredocs(command).prefix(Self.longest))
        }
        call.task = call.task.map { String($0.prefix(200)) }
        call.query = call.query.map { String($0.prefix(200)) }
        call.patch = call.patch.map { Self.compact(patch: $0) }
        byId[call.id] = calls.count
        calls.append(call)
    }

    /// The most of a command kept: past it, what it names is left out of the map.
    static let longest = 4000

    static func compact(patch: String) -> String {
        patch.split(separator: "\n").compactMap { line in
            line.hasPrefix("***") ? String(line) : line.first.flatMap { "+-".contains($0) ? String($0) : nil }
        }.joined(separator: "\n")
    }
}
