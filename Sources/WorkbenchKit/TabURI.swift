import Foundation
import Core

/// URI helpers: "session:ID", "file:///abs#L12", "diff:path", "https://…", "ext:id/view".
public enum TabURI {
    public static func scheme(_ uri: String) -> String {
        guard let i = uri.firstIndex(of: ":") else { return "file" }
        return uri[..<i].lowercased()
    }
    public static func body(_ uri: String) -> String {
        guard let i = uri.firstIndex(of: ":") else { return uri }
        return String(uri[uri.index(after: i)...])
    }
    /// It runs something instead of showing it: `terminal:?cmd=…`, `agent:?prompt=…`. Only `runURI` takes one.
    public static func runs(_ uri: String) -> Bool { ["terminal", "agent"].contains(scheme(uri)) }
    public static func session(_ id: String) -> String { "session:\(id)" }
    /// What a subagent of `session` did: a journal, it has no terminal.
    public static func subagent(session: String, id: String) -> String { "subagent:\(session)/\(id)" }
    public static func file(_ path: String, line: Int? = nil) -> String {
        "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + (line.map { "#L\($0)" } ?? "")
    }
    /// A prompt an agent handed over (`kelp edit`). The file beside it, with `promptDone` added, says the tab has closed.
    public static func prompt(_ path: String) -> String { "prompt:" + Core.Prompts.uriBody(path) }
    public static func promptPath(_ uri: String) -> String { body(uri).removingPercentEncoding ?? body(uri) }
    public static let promptDone = Core.Prompts.done
    /// A workspace's changes: all of them, one file's, a source's ("staged", "turn"…) or a commit's.
    public static func diff(_ worktree: String, file: String? = nil, source: String? = nil, commit: String? = nil) -> String {
        var c = URLComponents()
        c.queryItems = [("file", file), ("source", source), ("commit", commit)].compactMap { n, v in v.map { URLQueryItem(name: n, value: $0) } }
        return "diff:\(worktree)" + (c.queryItems?.isEmpty == false ? "?" + (c.percentEncodedQuery ?? "") : "")
    }
    /// Absolute path and line of a file URI (also accepts a bare path).
    public static func filePath(_ uri: String) -> (path: String, line: Int?) {
        var s = uri.hasPrefix("file://") ? String(uri.dropFirst(7)) : uri
        var line: Int?
        if let h = s.range(of: "#L") { line = Int(s[h.upperBound...]); s = String(s[..<h.lowerBound]) }
        return (s.removingPercentEncoding ?? s, line)
    }
    /// What the user typed or an agent sent: path, path:line, URL.
    public static func normalize(_ s: String, cwd: String?) -> String {
        if s.contains("://") || ["session:", "ext:", "diff:"].contains(where: s.hasPrefix) { return s }
        if s.hasPrefix("localhost") || s.hasPrefix("127.0.0.1") { return "http://" + s }
        var p = s, line: Int?
        if let r = s.range(of: #":(\d+)$"#, options: .regularExpression) { line = Int(s[r].dropFirst()); p = String(s[..<r.lowerBound]) }
        if !p.hasPrefix("/"), let cwd { p = (cwd as NSString).appendingPathComponent(p) }
        return file(p, line: line)
    }
}
