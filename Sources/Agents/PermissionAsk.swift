import Core
import Foundation

extension Hooks {
    /// What a hook's notification puts on the row. Claude Code's PermissionRequest (`kelp hook` passes it on as
    /// "permission_request" with its tool) comes as the dialog opens and says what it would run; the generic "Claude needs
    /// your permission to use Bash" Notification it sends six seconds later doesn't replace that.
    public static func message(_ notification: JSONValue, alreadyWaiting: Bool) -> String? {
        switch notification["notification_type"]?.string {
        case "permission_request": permissionAsk(notification)
        case "permission_prompt" where alreadyWaiting: nil
        default: notification["message"]?.string
        }
    }

    /// "Allow rm -rf node_modules?", "Allow editing Sources/App.swift?": the tool and what it would act on. A question
    /// (AskUserQuestion goes through the same dialog) is its own first question, not a permission.
    public static func permissionAsk(_ notification: JSONValue) -> String {
        let tool = notification["tool_name"]?.string ?? "", input = notification["tool_input"] ?? .null
        if tool == "AskUserQuestion", let question = input["questions"]?.array?.first?["question"]?.string.map(oneLine),
            !question.isEmpty
        {
            return question.count > 126 ? String(question.prefix(125)) + "…" : question
        }
        func field(_ key: String) -> String? { input[key]?.string.map(oneLine).flatMap { $0.isEmpty ? nil : $0 } }
        func file(_ key: String) -> String? { field(key).map { shortPath($0, cwd: notification["cwd"]?.string) } }
        // A command of more lines than shows ends "…": what's asked isn't all on screen (`Hooks.shownWhole`).
        let lines =
            input["command"]?.string?.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
            ?? 0
        let what: String? =
            switch tool {
            case "Bash": field("command").map { lines > 1 ? $0 + " …" : $0 }
            case "Edit", "MultiEdit", "NotebookEdit":
                file("file_path").map { "editing " + $0 } ?? file("notebook_path").map { "editing " + $0 }
            case "Write": file("file_path").map { "writing " + $0 }
            case "Read": file("file_path").map { "reading " + $0 }
            case "WebFetch": field("url").map { "fetching " + (URL(string: $0)?.host ?? $0) }
            case "WebSearch": field("query").map { "searching the web for “\($0)”" }
            default: nil
            }
        let name = tool.hasPrefix("mcp__") ? tool.dropFirst(5).replacingOccurrences(of: "__", with: ": ") : tool
        let text = what ?? (name.isEmpty ? "this" : name)
        return "Allow " + (text.count > 120 ? String(text.prefix(119)) + "…" : text) + "?"
    }

    /// What an AskUserQuestion dialog offers, by label: only for one question with one answer to pick, where a single click
    /// says all of it. A dialog of several questions, or of several answers each, is answered in the agent.
    public static func choices(_ notification: JSONValue) -> [String]? {
        guard notification["notification_type"]?.string == "permission_request",
            notification["tool_name"]?.string == "AskUserQuestion",
            let questions = notification["tool_input"]?["questions"]?.array, questions.count == 1,
            questions[0]["multiSelect"]?.bool != true
        else { return nil }
        let labels = questions[0]["options"]?.array?.compactMap { $0["label"]?.string.map(oneLine) } ?? []
        return labels.isEmpty || labels.contains(where: \.isEmpty) ? nil : labels
    }

    /// Whether a permission's question shows all it would allow: one cut short or a command of several lines doesn't,
    /// so it is answered in the agent's own dialog, never with one click on a banner or the Dock.
    public static func shownWhole(_ question: String) -> Bool { !question.hasSuffix("…?") }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Inside the session's folder: relative to it; elsewhere in the home folder: from "~".
    private static func shortPath(_ path: String, cwd: String?) -> String {
        if let cwd, path.hasPrefix(cwd.hasSuffix("/") ? cwd : cwd + "/") {
            return String(path.dropFirst(cwd.count).drop { $0 == "/" })
        }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

extension Session {
    /// "Claude needs your permission to use Bash", a blocked OSC report of kind permission…
    /// Only one whose question shows all of it gets Allow / Deny where it's shown (`Hooks.shownWhole`).
    public var asksPermission: Bool {
        let summary = summary.lowercased()
        return status == .waiting && ["permission", "approve", "allow"].contains { summary.contains($0) }
            && Hooks.shownWhole(self.summary)
    }
}
