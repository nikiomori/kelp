import Foundation

/// Builds and reads the address of a database tab, `db:<workspace>/<name>`. The tab can show one run (`?run=`), one
/// table (`?table=`), or how a branch's copy differs from the database it copies (`?compare=<original>`). The name and
/// the table are percent-encoded, because an imported name may hold a "?" or "/". This is the only place that builds
/// the address (for the tab, the agent's row and `kelp db`) and the only place that reads it (`parts`). The daemon
/// decides whether an agent may open a tab by the workspace and database the tab will show, so both sides must read an
/// address the same way.
public enum DatabaseTabURI {
    /// Returns the workspace and database that `uri` names, and the text after its "?". Returns nil when `uri` isn't a
    /// database tab's address.
    public static func parts(_ uri: String) -> (worktree: String, name: String, query: String?)? {
        guard let colon = uri.firstIndex(of: ":"), uri[..<colon].lowercased() == "db" else { return nil }
        let body = uri[uri.index(after: colon)...].split(separator: "?", maxSplits: 1)
        let parts = body.first?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1].removingPercentEncoding ?? parts[1], body.count > 1 ? String(body[1]) : nil)
    }

    public static func uri(
        worktree: String, name: String, run: String? = nil, table: String? = nil, compare: String? = nil
    ) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?/")
        let name = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let table = table.map { "?table=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) }
        let compare = compare.map { "?compare=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0) }
        return "db:\(worktree)/\(name)" + (run.map { "?run=" + $0 } ?? table ?? compare ?? "")
    }
}
