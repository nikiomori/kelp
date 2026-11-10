import Foundation

/// How a command run in a folder reaches the app: the tab URI a target means, the workspace a folder is in, `ui.open`.
public enum IDE {
    // MARK: open

    /// What `ui.open` gets for a CLI/agent target: http(s) and tab URIs as is, `path:12` → `file:///abs/path#L12`, other paths made absolute.
    public static func uri(for target: String, cwd: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
        if let match = target.wholeMatch(of: /(.+):(\d+)/) {
            return URL(fileURLWithPath: absolute(String(match.1), cwd: cwd)).absoluteString + "#L\(match.2)"
        }
        let path = absolute(target, cwd: cwd)
        if target.wholeMatch(of: /[a-z][a-z0-9+.-]*:.*/) != nil, !FileManager.default.fileExists(atPath: path) {
            return target
        }   // session:, diff:, ext:…
        return path
    }

    /// Opens `target` in the editor area of the workspace that contains `cwd` (when there is one).
    /// `focus`: bring Kelp to the front and switch to that workspace (otherwise the tab waits there quietly).
    public static func open(_ target: String, split: String?, cwd: String, focus: Bool = false, client: RPCClient)
        async throws -> Delivered
    {
        let found = try await workspace(cwd: cwd, client: client)
        return try await client.call(
            UIOpen(uri: uri(for: target, cwd: cwd), split: split, focus: focus ? true : nil, worktreeId: found?.id))
    }

    /// The workspace a command run in `cwd` means (`workspace(cwd:among:own:)`), from the daemon's lists.
    public static func workspace(
        cwd: String, session: String? = ProcessInfo.processInfo.environment["KELP_SESSION"],
        client: RPCClient
    ) async throws -> Worktree? {
        let all = try await client.call(WorktreeList())
        let own = session == nil ? nil : try await client.call(SessionList()).first { $0.id == session }?.worktreeId
        return workspace(cwd: cwd, among: all, own: own)
    }

    /// Workspaces of a project share its folder, so the folder alone can't tell them apart: the agent's own (`own`, its
    /// KELP_SESSION's workspace) wins when it holds `cwd`, else the first one that does.
    public static func workspace(cwd: String, among all: [Worktree], own: String?) -> Worktree? {
        let here = all.filter { Paths.inside(cwd, $0.path) }
        return here.first { $0.id == own } ?? here.first
    }

    static func absolute(_ path: String, cwd: String) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
    }
}
