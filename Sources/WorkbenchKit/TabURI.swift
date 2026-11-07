import Core
import Foundation

/// URI helpers: "session:ID", "file:///abs#L12", "diff:path", "https://…", "ext:id/view".
public enum TabURI {
    public static func scheme(_ uri: String) -> String {
        guard let colon = uri.firstIndex(of: ":") else { return "file" }
        return uri[..<colon].lowercased()
    }
    public static func body(_ uri: String) -> String {
        guard let colon = uri.firstIndex(of: ":") else { return uri }
        return String(uri[uri.index(after: colon)...])
    }
    /// It runs something instead of showing it: `terminal:?cmd=…`, `agent:?prompt=…`. Only `runURI` takes one.
    public static func runs(_ uri: String) -> Bool { ["terminal", "agent"].contains(scheme(uri)) }
    public static func session(_ id: String) -> String { "session:\(id)" }
    /// A page an agent drives (`kelp browser open`), with cookies and storage of its own: `agentweb:` and its address.
    public static let agentScheme = "agentweb"
    public static func agentPage(_ url: String) -> String { agentScheme + ":" + url }
    /// The address a page's tab shows (an agent's without its prefix).
    public static func pageURL(_ uri: String) -> String { scheme(uri) == agentScheme ? body(uri) : uri }
    /// A tab that shows a web page: `kelp browser` can drive it.
    public static func isPage(_ uri: String) -> Bool {
        ["http", "https", "about", "preview", agentScheme].contains(scheme(uri))
    }
    /// What a subagent of `session` did: a journal, it has no terminal.
    public static func subagent(session: String, id: String) -> String { "subagent:\(session)/\(id)" }
    public static func file(_ path: String, line: Int? = nil) -> String {
        "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
            + (line.map { "#L\($0)" } ?? "")
    }
    /// A prompt an agent handed over (`kelp edit`). The file beside it, with `promptDone` added, says the tab has closed.
    public static func prompt(_ path: String) -> String { "prompt:" + Core.Prompts.uriBody(path) }
    public static func promptPath(_ uri: String) -> String { body(uri).removingPercentEncoding ?? body(uri) }
    public static let promptDone = Core.Prompts.done
    /// A workspace's changes: all of them, one file's, a source's ("staged", "turn"…) or a commit's.
    public static func diff(_ worktree: String, file: String? = nil, source: String? = nil, commit: String? = nil)
        -> String
    {
        var components = URLComponents()
        components.queryItems = [("file", file), ("source", source), ("commit", commit)].compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        return "diff:\(worktree)"
            + (components.queryItems?.isEmpty == false ? "?" + (components.percentEncodedQuery ?? "") : "")
    }
    /// Absolute path and line of a file URI (also accepts a bare path).
    public static func filePath(_ uri: String) -> (path: String, line: Int?) {
        var path = uri.hasPrefix("file://") ? String(uri.dropFirst(7)) : uri
        var line: Int?
        if let anchor = path.range(of: "#L") {
            line = Int(path[anchor.upperBound...])
            path = String(path[..<anchor.lowerBound])
        }
        return (path.removingPercentEncoding ?? path, line)
    }
    /// What the user typed or an agent sent: path, path:line, URL.
    public static func normalize(_ s: String, cwd: String?) -> String {
        if s.contains("://") || ["session:", "ext:", "diff:"].contains(where: s.hasPrefix) { return s }
        if s.hasPrefix("localhost") || s.hasPrefix("127.0.0.1") { return "http://" + s }
        var path = s, line: Int?
        if let match = s.range(of: #":(\d+)$"#, options: .regularExpression) {
            line = Int(s[match].dropFirst())
            path = String(s[..<match.lowerBound])
        }
        if !path.hasPrefix("/"), let cwd { path = (cwd as NSString).appendingPathComponent(path) }
        return file(path, line: line)
    }
}
