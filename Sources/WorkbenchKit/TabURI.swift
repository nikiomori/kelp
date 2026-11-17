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
    /// Whether the URI runs something instead of showing it (`terminal:?cmd=…`, `agent:?prompt=…`). Only `runURI` takes
    /// such a URI.
    public static func runs(_ uri: String) -> Bool { ["terminal", "agent"].contains(scheme(uri)) }
    public static func session(_ id: String) -> String { "session:\(id)" }
    /// A new terminal tab: a shell where it opens, or what `query` says it runs (`tmux`, `cmd`, `script`, `title`).
    public static func terminal(_ query: KeyValuePairs<String, String?> = [:]) -> String {
        var components = URLComponents()
        components.scheme = "terminal"
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.string ?? "terminal:"
    }
    /// A new tab of the agent `id`.
    public static func agent(_ id: String) -> String { "agent:" + id }
    /// A page an agent drives (`kelp browser open`), with cookies and storage of its own: `agentweb:` and its address.
    public static let agentScheme = "agentweb"
    public static func agentPage(_ url: String) -> String { agentScheme + ":" + url }
    /// The address that a page's tab shows, with an agent page's prefix taken off.
    public static func pageURL(_ uri: String) -> String { scheme(uri) == agentScheme ? body(uri) : uri }
    /// Whether a tab shows a web page, which `kelp browser` can drive.
    public static func isPage(_ uri: String) -> Bool {
        ["http", "https", "about", "preview", agentScheme].contains(scheme(uri))
    }
    /// A pull request in Kelp's own tab (the Issues tab), wherever it is opened from: the Issues panel, the PR mark on
    /// a row or in the window bar, or Quick Open's "#". `repo` is the project's id.
    public static func pullRequest(repo: String, number: Int) -> String { "pr:\(repo)/\(number)" }
    /// A tab that shows what a subagent of `session` did as a journal, because a subagent has no terminal.
    public static func subagent(session: String, id: String) -> String { "subagent:\(session)/\(id)" }
    public static func file(_ path: String, line: Int? = nil) -> String {
        "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
            + (line.map { "#L\($0)" } ?? "")
    }
    /// A prompt an agent handed over (`kelp edit`). The file beside it, with `promptDone` added, says the tab has closed.
    public static func prompt(_ path: String) -> String { "prompt:" + Core.Prompts.uriBody(path) }
    public static func promptPath(_ uri: String) -> String { body(uri).removingPercentEncoding ?? body(uri) }
    public static let promptDone = Core.Prompts.done
    /// A workspace's changes: all of them, one file's changes, one source's ("staged", "turn"…), or one commit's.
    public static func diff(
        _ worktree: String, file: String? = nil, source: GitDiff.Source? = nil, commit: String? = nil
    ) -> String {
        var components = URLComponents()
        let items = [("file", file), ("source", source?.rawValue), ("commit", commit)]
        components.queryItems = items.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
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
    /// Turns what the user typed or an agent sent (a path, path:line, a URL) into a URI.
    public static func normalize(_ typed: String, cwd: String?) -> String {
        if typed.contains("://") || ["session:", "ext:", "diff:"].contains(where: typed.hasPrefix) { return typed }
        if typed.hasPrefix("localhost") || typed.hasPrefix("127.0.0.1") { return "http://" + typed }
        var path = typed, line: Int?
        if let match = typed.range(of: #":(\d+)$"#, options: .regularExpression) {
            line = Int(typed[match].dropFirst())
            path = String(typed[..<match.lowerBound])
        }
        if !path.hasPrefix("/"), let cwd { path = (cwd as NSString).appendingPathComponent(path) }
        return file(path, line: line)
    }
}
