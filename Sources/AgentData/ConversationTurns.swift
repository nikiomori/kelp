import Core
import Foundation

/// A conversation as someone away from the terminal reads it, on the phone's page. It holds what the user asked, what
/// the agent said, and one line for each run of tools in between, summed up the way the agent's terminal does ("Read 3
/// files, ran 1 command"). It comes from Claude Code's transcript or Codex's rollout. Other agents' files aren't read.
public enum ConversationTurns {
    public struct Turn: Equatable, Sendable {
        public enum Role: String, Sendable { case user, did, agent }
        public var role: Role, text: String
        /// When the user asked, as the file has it (ISO 8601).
        public var at: String?
        public init(role: Role, text: String, at: String? = nil) {
            self.role = role
            self.text = text
            self.at = at
        }
    }

    /// Returns the last turns of the conversation in `url` that fit in `limit` bytes of text, oldest first. Only the
    /// last megabytes of a long file are read. A turn longer than a quarter of the limit is cut: what the agent said
    /// keeps its end, and what the user asked keeps its start.
    public static func last(in url: URL, limit: Int = 256 << 10) -> [Turn] {
        Data(tail: 4 << 20, of: url).map { last(inTail: $0, limit: limit) } ?? []
    }

    /// Does the same with the last bytes of a conversation file that were read elsewhere (for a remote project, on its
    /// host).
    public static func last(inTail data: Data, limit: Int = 256 << 10) -> [Turn] {
        var reader = Reader()
        for line in JSONL.lines(data) { if let entry = JSONL.object(line) { reader.read(entry) } }
        reader.endRun()
        return fitting(reader.turns, limit: limit)
    }

    static func fitting(_ turns: [Turn], limit: Int) -> [Turn] {
        var left = limit, kept: [Turn] = []
        for var turn in turns.reversed() {
            if turn.text.utf8.count > limit / 4 {
                let cut = limit / 4
                turn.text = turn.role == .user ? String(turn.text.prefix(cut)) + "…" : "…" + turn.text.suffix(cut)
            }
            left -= turn.text.utf8.count
            guard left >= 0 else { break }
            kept.append(turn)
        }
        return kept.reversed()
    }

    /// Reads one file's lines in order. Words become turns, and the tools used between them become one `did` line.
    struct Reader {
        var turns: [Turn] = []
        private var run = Run()

        /// Reads one entry: Claude Code's `{type: user|assistant, message, timestamp}`, or Codex's
        /// `{type: response_item, payload}` holding a message or a tool call.
        mutating func read(_ entry: [String: Any]) {
            let payload = entry["payload"] as? [String: Any], at = entry["timestamp"] as? String
            switch (entry["type"] as? String, payload?["type"] as? String) {
            case (let role?, _) where role == "user" || role == "assistant":
                // A subagent's lines, Claude Code's own notes and a compaction's summary are skipped, because no one
                // said them.
                guard entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true,
                    entry["isCompactSummary"] as? Bool != true
                else { return }
                say(role, (entry["message"] as? [String: Any])?["content"], at: at)
            case ("response_item", "message"?): say(payload?["role"] as? String, payload?["content"], at: at)
            case ("response_item", let kind?) where kind.hasSuffix("_call"):
                let sent = payload?["arguments"] ?? payload?["input"] ?? payload?["action"]
                let name = payload?["name"] as? String ?? (kind == "local_shell_call" ? "shell" : nil)
                run.used(name, (sent as? String).flatMap { JSONL.object(Data($0.utf8)) } ?? sent)
            default: break
            }
        }

        private mutating func say(_ role: String?, _ content: Any?, at: String?) {
            guard role == "user" || role == "assistant" else { return }
            let items = content as? [[String: Any]] ?? []
            let texts = (content as? String).map { [$0] } ?? items.compactMap { $0["text"] as? String }
            let text = texts.compactMap(role == "user" ? JSONL.typed : Self.said).joined(separator: "\n\n")
            if !text.isEmpty {
                endRun()
                let turn = Turn(role: role == "user" ? .user : .agent, text: text, at: role == "user" ? at : nil)
                if turn.role == .agent, turns.last?.role == .agent, let last = turns.indices.last {
                    turns[last].text += "\n\n" + text
                } else {
                    turns.append(turn)
                }
            }
            for item in items where item["type"] as? String == "tool_use" {
                run.used(item["name"] as? String, item["input"])
            }
        }

        /// The tools used since the last words, as one line.
        mutating func endRun() {
            if let line = run.line { turns.append(Turn(role: .did, text: line)) }
            run = Run()
        }

        private static func said(_ raw: String) -> String? {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// Counts the tools an agent used in a row, grouped by what they did.
    struct Run {
        var patterns = 0, commands = 0, others = 0
        var read: [String] = [], edited: [String] = []

        /// Counts one tool call: Claude Code's Read/Grep/Glob/Edit/Write/Bash, or Codex's shell, exec_command,
        /// apply_patch and exec. A plan or a to-do list doesn't count as work done.
        mutating func used(_ name: String?, _ sent: Any?) {
            guard let name = name?.lowercased() else { return }
            let args = sent as? [String: Any]
            func path() -> String? { (args?["file_path"] ?? args?["notebook_path"] ?? args?["path"]) as? String }
            switch name {
            case "read": note(path(), in: &read)
            case "grep", "glob": patterns += 1
            case "edit", "write", "multiedit", "notebookedit": note(path(), in: &edited)
            case "apply_patch", "exec":
                // Codex's code mode runs its tools from a script (`exec`). A patch in the script names the files it
                // edits, and a script without a patch counts as a command.
                let script = sent as? String ?? args?["input"] as? String ?? args?["patch"] as? String ?? ""
                let files = script.matches(of: /\*\*\* (?:Update|Add|Delete) File: ([^\\\n"]+)/)
                for file in files { note(String(file.1), in: &edited) }
                if files.isEmpty, name == "exec" { commands += 1 }
            case "bash", "shell", "shell_command", "exec_command", "local_shell": commands += 1
            case "todowrite", "update_plan": break
            default: others += 1
            }
        }

        private func note(_ path: String?, in list: inout [String]) {
            if let path, !path.isEmpty, !list.contains(path) { list.append(path) }
        }

        /// The run as one line, such as "Searched for 2 patterns, read 4 files" or "Edited Queue.swift,
        /// SyncTests.swift". It is nil when nothing was done.
        var line: String? {
            func count(_ number: Int, _ one: String, _ many: String) -> String? {
                number == 0 ? nil : "\(number) \(number == 1 ? one : many)"
            }
            var parts = [
                count(patterns, "pattern", "patterns").map { "searched for " + $0 },
                count(read.count, "file", "files").map { "read " + $0 },
                count(edited.count, "file", "files").map { "edited " + $0 },
                count(commands, "command", "commands").map { "ran " + $0 },
                count(others, "tool", "tools").map { "used " + $0 }
            ].compactMap { $0 }
            // When a few files changed and nothing else happened, their names say more than their number.
            if parts.count == 1, (1...3).contains(edited.count) {
                parts = ["edited " + edited.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")]
            }
            guard let first = parts.first else { return nil }
            return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
        }
    }
}
