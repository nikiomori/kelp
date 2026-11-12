import Core
import Foundation

/// A conversation as someone away from the terminal reads it (the phone's page): what the user asked, what the agent
/// said, and each run of its tools between as one line, the way its terminal sums one up ("Read 3 files, ran 1
/// command"). From Claude Code's transcript or Codex's rollout; other agents' files aren't read.
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

    /// The last turns of the conversation in `url` that fit in `limit` bytes of text, oldest first. The file's last
    /// megabytes are read, not all of a long one; a turn longer than a quarter of the limit keeps its end (what the
    /// agent said) or its start (what was asked).
    public static func last(in url: URL, limit: Int = 256 << 10) -> [Turn] {
        guard let data = Data(tail: 4 << 20, of: url) else { return [] }
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

    /// One file's lines, in order: words become turns, the tools used between them one `did` line.
    struct Reader {
        var turns: [Turn] = []
        private var run = Run()

        /// Claude Code's `{type: user|assistant, message, timestamp}`; Codex's `{type: response_item, payload}` with a
        /// message or a tool's call.
        mutating func read(_ entry: [String: Any]) {
            let payload = entry["payload"] as? [String: Any], at = entry["timestamp"] as? String
            switch (entry["type"] as? String, payload?["type"] as? String) {
            case (let role?, _) where role == "user" || role == "assistant":
                // A subagent's lines, Claude Code's own notes and a compaction's summary are nobody's words.
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
            let text = texts.compactMap(role == "user" ? Self.asked : Self.said).joined(separator: "\n\n")
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

        /// What a person typed: not what a program put in their name (`<system-reminder>`, a command's output,
        /// Codex's AGENTS.md and environment). A slash command with arguments reads "/name args".
        private static func asked(_ raw: String) -> String? {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("<command-"), let name = text.firstMatch(of: /<command-name>(.*?)<\/command-name>/)?.1,
                let args = text.firstMatch(of: /<command-args>([\s\S]*?)<\/command-args>/)?.1,
                !args.allSatisfy(\.isWhitespace)
            {
                return "\(name) \(args)"
            }
            let notTyped =
                text.isEmpty || text.hasPrefix("<") || text.hasPrefix("# AGENTS.md")
                || text.hasPrefix("[Request interrupted")
            return notTyped ? nil : text
        }
    }

    /// The tools an agent used in a row, by what they did.
    struct Run {
        var patterns = 0, commands = 0, others = 0
        var read: [String] = [], edited: [String] = []

        /// Claude Code's Read/Grep/Glob/Edit/Write/Bash, Codex's shell, exec_command, apply_patch and exec; a plan or
        /// a to-do list is no work done.
        mutating func used(_ name: String?, _ sent: Any?) {
            guard let name = name?.lowercased() else { return }
            let args = sent as? [String: Any]
            func path() -> String? { (args?["file_path"] ?? args?["notebook_path"] ?? args?["path"]) as? String }
            switch name {
            case "read": note(path(), in: &read)
            case "grep", "glob": patterns += 1
            case "edit", "write", "multiedit", "notebookedit": note(path(), in: &edited)
            case "apply_patch", "exec":
                // Codex's code mode runs its tools from a script (`exec`): a patch in it names its files, anything
                // else there is a command.
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

        /// "Searched for 2 patterns, read 4 files", "Edited Queue.swift, SyncTests.swift"; nil when nothing was done.
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
            // A few files changed and nothing else: their names say more than their number.
            if parts.count == 1, (1...3).contains(edited.count) {
                parts = ["edited " + edited.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")]
            }
            guard let first = parts.first else { return nil }
            return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
        }
    }
}
