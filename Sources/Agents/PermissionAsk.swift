import Foundation
import Core

extension Hooks {
    /// What a hook's notification puts on the row. Claude Code's PermissionRequest (`kelp hook` passes it on as
    /// "permission_request" with its tool) comes as the dialog opens and says what it would run; the generic "Claude needs
    /// your permission to use Bash" Notification it sends six seconds later doesn't replace that.
    public static func message(_ n: JSONValue, alreadyWaiting: Bool) -> String? {
        switch n["notification_type"]?.string {
        case "permission_request": permissionAsk(n)
        case "permission_prompt" where alreadyWaiting: nil
        default: n["message"]?.string
        }
    }

    /// "Allow rm -rf node_modules?", "Allow editing Sources/App.swift?": the tool and what it would act on.
    public static func permissionAsk(_ n: JSONValue) -> String {
        let tool = n["tool_name"]?.string ?? "", input = n["tool_input"] ?? .null
        func field(_ key: String) -> String? { input[key]?.string.map(oneLine).flatMap { $0.isEmpty ? nil : $0 } }
        func file(_ key: String) -> String? { field(key).map { shortPath($0, cwd: n["cwd"]?.string) } }
        let what: String? = switch tool {
        case "Bash": field("command")
        case "Edit", "MultiEdit", "NotebookEdit": file("file_path").map { "editing " + $0 } ?? file("notebook_path").map { "editing " + $0 }
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

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Inside the session's folder: relative to it; elsewhere in the home folder: from "~".
    private static func shortPath(_ path: String, cwd: String?) -> String {
        if let cwd, path.hasPrefix(cwd.hasSuffix("/") ? cwd : cwd + "/") { return String(path.dropFirst(cwd.count).drop { $0 == "/" }) }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
