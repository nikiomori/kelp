import Foundation

/// What an agent's conversation file says, read for the agent it's handed to (session.handoff): Claude Code's transcript,
/// Codex's rollout, pi's or oh-my-pi's session. What was said, and what was done beside it: the files it changed, the
/// commands it ran, its last plan.
struct Conversation {
    struct Turn: Equatable {
        var user: Bool, text: String
    }
    var turns: [Turn] = []
    /// Files it wrote or edited, in the order first touched.
    var changed: [String] = []
    /// Commands it ran, each once, the latest run last.
    var commands: [String] = []
    /// Its last plan or to-do list, as "[x] step" lines.
    var plan: [String] = []

    init() {}

    /// Nil when the file can't be read or holds nothing anyone said.
    init?(file url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for line in data.split(separator: 0x0A) {
            if let entry = Self.json(Data(line)) { read(entry) }
        }
        guard !turns.isEmpty else { return nil }
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// One line: Claude Code's `{type: user|assistant, message}`, pi's `{type: message, message: {role}}`, Codex's
    /// `{payload: {type: message, role}}`, its tool calls and what its turns did (`item_completed`).
    private mutating func read(_ entry: [String: Any]) {
        let message = entry["message"] as? [String: Any], payload = entry["payload"] as? [String: Any]
        switch (entry["type"] as? String, payload?["type"] as? String) {
        case (let type?, _) where type == "user" || type == "assistant": say(type, message?["content"])
        case ("message", _): say(message?["role"] as? String, message?["content"])
        case ("response_item", "message"?): say(payload?["role"] as? String, payload?["content"])
        case ("response_item", "function_call"?):
            used(payload?["name"] as? String, Self.json(Data(((payload?["arguments"] as? String) ?? "").utf8)))
        case ("event_msg", "item_completed"?): did(payload?["item"] as? [String: Any] ?? [:])
        default: break
        }
    }

    /// A user's or the agent's words (tool results, system notes, Codex's AGENTS.md and developer notes aren't), joined to
    /// the turn before when the same side spoke; the tool calls among them.
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

    /// A tool call by name: Claude Code's Edit/Write/Bash/TodoWrite, pi's edit/write/bash, Codex's shell/update_plan.
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

    /// What a Codex turn did, whichever tool did it (its code mode runs tools from a script).
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

    /// A command as typed: Codex's `["bash", "-lc", "…"]` is its last part.
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

    /// The first turn (the task, up to a quarter of `limit`) and as many of the newest as fit in `limit` characters;
    /// the newest one that doesn't fit whole keeps its end.
    func kept(limit: Int) -> [Turn] {
        guard var first = turns.first else { return [] }
        if first.text.count > limit / 4 { first.text = String(first.text.prefix(limit / 4)) + "…" }
        var budget = limit - first.text.count, tail: [Turn] = []
        for turn in turns.dropFirst().reversed() where budget > 0 {
            tail.append(turn.text.count <= budget ? turn : Turn(user: turn.user, text: "…" + turn.text.suffix(budget)))
            budget -= turn.text.count
        }
        return [first] + tail.reversed()
    }

    /// The plan, the files, the last 15 commands and what git says is uncommitted: what the turns don't say.
    func notes(uncommitted: String) -> String {
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

    /// "## You / ## Agent" turns after the notes; "…" where turns were left out.
    func markdown(limit: Int, uncommitted: String = "") -> String {
        let kept = kept(limit: limit)
        var parts = kept.map { "## \($0.user ? "You" : "Agent")\n\n\($0.text)" }
        if kept.count < turns.count { parts.insert("…", at: 1) }
        let notes = notes(uncommitted: uncommitted)
        return ((notes.isEmpty ? [] : [notes, "# Conversation"]) + parts).joined(separator: "\n\n")
    }

    /// The turns as a pi session (pi's docs/session-format.md, version 3) that `pi --session` and `omp --resume` open as
    /// their own: one message per turn, each the child of the one before, and the notes as a message the model reads
    /// (`custom_message`). The answers are marked as another program's (`api`), so pi sends them as plain text.
    func piSession(cwd: String, agent: String, limit: Int, uncommitted: String, now: Date = Date()) throws -> String {
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
