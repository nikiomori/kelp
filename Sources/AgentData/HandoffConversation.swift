import Core
import Foundation

/// An agent's conversation file, read for the agent the work is handed to (session.handoff). The file is Claude
/// Code's transcript, Codex's rollout, or pi's or oh-my-pi's session. It holds what was said and what was done
/// alongside: the files changed, the commands run, and the last plan.
public struct Conversation: Sendable {
    public struct Turn: Equatable, Sendable {
        public var user: Bool, text: String
        public init(user: Bool, text: String) {
            self.user = user
            self.text = text
        }
    }
    public var turns: [Turn] = []
    /// Files the agent wrote or edited, in the order they were first touched.
    public var changed: [String] = []
    /// Commands the agent ran, each listed once, with the most recent last.
    public var commands: [String] = []
    /// The agent's last plan or to-do list, as "[x] step" lines.
    public var plan: [String] = []

    public init() {}

    /// Reads a conversation file. Returns nil when the file can't be read or holds nothing anyone said.
    public init?(file url: URL) {
        guard let data = Data(contentsIfAny: url) else { return nil }
        for line in JSONL.lines(data) {
            if let entry = JSONL.object(line) { read(entry) }
        }
        guard !turns.isEmpty else { return nil }
    }

    /// Parses one line of a conversation file: Claude Code's `{type: user|assistant, message}`, pi's `{type: message,
    /// message: {role}}`, or Codex's `{payload: {type: message, role}}`, including Codex's tool calls and what Codex's
    /// turns did (`item_completed`).
    private mutating func read(_ entry: [String: Any]) {
        let message = entry["message"] as? [String: Any], payload = entry["payload"] as? [String: Any]
        switch (entry["type"] as? String, payload?["type"] as? String) {
        case (let type?, _) where type == "user" || type == "assistant": say(type, message?["content"])
        case ("message", _): say(message?["role"] as? String, message?["content"])
        case ("response_item", "message"?): say(payload?["role"] as? String, payload?["content"])
        case ("response_item", "function_call"?):
            used(payload?["name"] as? String, JSONL.object(Data(((payload?["arguments"] as? String) ?? "").utf8)))
        case ("event_msg", "item_completed"?): did(payload?["item"] as? [String: Any] ?? [:])
        default: break
        }
    }

    /// Adds a user's or the agent's words, joined to the previous turn when the same side spoke. Tool results, system
    /// notes, and Codex's AGENTS.md and developer notes aren't words. It also records the tool calls in the content.
    private mutating func say(_ role: String?, _ content: Any?) {
        guard role == "user" || role == "assistant" else { return }
        let items = content as? [[String: Any]] ?? []
        for item in items where ["tool_use", "toolCall"].contains(item["type"] as? String) {
            used(item["name"] as? String, (item["input"] ?? item["arguments"]) as? [String: Any])
        }
        let text = ((content as? String) ?? items.compactMap { $0["text"] as? String }.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md") else { return }
        let user = role == "user"
        if turns.last?.user == user, let last = turns.indices.last {
            turns[last].text += "\n\n" + text
        } else {
            turns.append(Turn(user: user, text: text))
        }
    }

    /// Records a tool call by its name: Claude Code's Edit/Write/Bash/TodoWrite, pi's edit/write/bash, or Codex's
    /// shell/update_plan.
    private mutating func used(_ name: String?, _ args: [String: Any]?) {
        guard let name = name?.lowercased(), let args else { return }
        switch name {
        case "edit", "write", "multiedit", "notebookedit":
            touched((args["file_path"] ?? args["notebook_path"] ?? args["path"]) as? String)
        case "bash", "shell", "exec_command": ran(args["command"] ?? args["cmd"])
        case "todowrite":
            plan = (args["todos"] as? [[String: Any]] ?? []).map { Self.step($0["content"], $0["status"]) }
        case "update_plan":
            plan = (args["plan"] as? [[String: Any]] ?? []).map { Self.step($0["step"], $0["status"]) }
        default: break
        }
    }

    /// Records what a Codex turn did, whichever tool did it, because Codex's code mode runs tools from a script.
    private mutating func did(_ item: [String: Any]) {
        switch item["type"] as? String {
        case "CommandExecution":
            ran((item["parsed_cmd"] as? [[String: Any]])?.first?["cmd"] ?? (item["command"] as? [String])?.last)
        case "FileChange": (item["changes"] as? [String: Any])?.keys.sorted().forEach { touched($0) }
        default: break
        }
    }

    private mutating func touched(_ path: String?) {
        if let path, !path.isEmpty, !changed.contains(path) { changed.append(path) }
    }

    /// Records a command as it was typed. For Codex's `["bash", "-lc", "…"]`, that is the last part.
    private mutating func ran(_ command: Any?) {
        guard
            let text = (command as? String ?? (command as? [String])?.last)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return }
        commands.removeAll { $0 == text }
        commands.append(text)
    }

    private static func step(_ text: Any?, _ status: Any?) -> String {
        "[\(status as? String == "completed" ? "x" : status as? String == "in_progress" ? "~" : " ")] \(text ?? "")"
    }

    /// Returns the first turn (the task, cut to a quarter of `limit`) and as many of the newest turns as fit in `limit`
    /// characters. The turn where the space runs out keeps only its end.
    public func kept(limit: Int) -> [Turn] {
        guard var first = turns.first else { return [] }
        if first.text.count > limit / 4 { first.text = String(first.text.prefix(limit / 4)) + "…" }
        var budget = limit - first.text.count, tail: [Turn] = []
        for turn in turns.dropFirst().reversed() where budget > 0 {
            tail.append(turn.text.count <= budget ? turn : Turn(user: turn.user, text: "…" + turn.text.suffix(budget)))
            budget -= turn.text.count
        }
        return [first] + tail.reversed()
    }

    /// Returns what the turns don't say: the plan, the changed files, the last 15 commands, and what git says is
    /// uncommitted.
    public func notes(uncommitted: String) -> String {
        var parts: [String] = []
        if !plan.isEmpty { parts.append("## Its plan\n\n" + plan.joined(separator: "\n")) }
        if !changed.isEmpty {
            parts.append("## Files it changed\n\n" + changed.prefix(100).map { "- \($0)" }.joined(separator: "\n"))
        }
        if !commands.isEmpty {
            parts.append(
                "## Commands it ran (the last \(min(commands.count, 15)))\n\n"
                    + commands.suffix(15).map { "- `\(String($0.prefix(300)))`" }.joined(separator: "\n"))
        }
        if !uncommitted.isEmpty { parts.append("## Uncommitted now (git status)\n\n```\n\(uncommitted)\n```") }
        return parts.joined(separator: "\n\n")
    }

    /// Returns the notes, then the turns under "## You" and "## Agent" headings, with "…" where turns were left out.
    public func markdown(limit: Int, uncommitted: String = "") -> String {
        let kept = kept(limit: limit)
        var parts = kept.map { "## \($0.user ? "You" : "Agent")\n\n\($0.text)" }
        if kept.count < turns.count { parts.insert("…", at: 1) }
        let notes = notes(uncommitted: uncommitted)
        return ((notes.isEmpty ? [] : [notes, "# Conversation"]) + parts).joined(separator: "\n\n")
    }

    /// Writes the turns as a pi session (pi's docs/session-format.md, version 3) that `pi --session` and
    /// `omp --resume` open as their own. Each turn is one message and the child of the message before it. The notes
    /// become a message the model reads (`custom_message`). The agent's answers are marked as coming from another
    /// program (`api`), so pi sends them as plain text.
    public func piSession(
        cwd: String, agent: String, limit: Int, uncommitted: String, now: Date = Date()
    ) throws -> String {
        let time = ISO8601DateFormatter.string(
            from: now, timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let none: [String: Any] = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]
        let usage: [String: Any] = [
            "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0, "cost": none
        ]
        var lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": UUID().uuidString.lowercased(), "timestamp": time, "cwd": cwd]
        ]
        var parent: Any = NSNull()
        func add(_ entry: [String: Any]) {
            let id = String(format: "%08x", lines.count)
            lines.append(entry.merging(["id": id, "parentId": parent, "timestamp": time]) { new, _ in new })
            parent = id
        }
        for turn in kept(limit: limit) {
            var message: [String: Any] = [
                "role": turn.user ? "user" : "assistant", "content": [["type": "text", "text": turn.text]],
                "timestamp": ms
            ]
            if !turn.user {
                message.merge([
                    "api": "kelp-handoff", "provider": agent, "model": agent, "usage": usage, "stopReason": "stop"
                ]) { new, _ in new }
            }
            add(["type": "message", "message": message])
        }
        let notes = notes(uncommitted: uncommitted)
        if !notes.isEmpty {
            add([
                "type": "custom_message", "customType": "kelp-handoff", "display": true,
                "content": "What the previous agent (\(agent)) did besides talking:\n\n" + notes
            ])
        }
        return try lines.map {
            String(
                bytes: try JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes, .sortedKeys]),
                encoding: .utf8) ?? ""
        }
        .joined(separator: "\n") + "\n"
    }
}
