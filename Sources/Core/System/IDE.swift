import Foundation

/// How a command run in a folder reaches the app: the tab URI a target means, the workspace a folder is in, and
/// `ui.open`.
public enum IDE {
    // MARK: open

    /// Returns the URI that `ui.open` gets for a CLI or agent target. http(s) and tab URIs pass as they are,
    /// `path:12` becomes `file:///abs/path#L12`, and other paths are made absolute.
    public static func uri(for target: String, cwd: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
        if let match = target.wholeMatch(of: /(.+):(\d+)/) {
            return URL(fileURLWithPath: absolute(String(match.1), cwd: cwd)).absoluteString + "#L\(match.2)"
        }
        let path = absolute(target, cwd: cwd)
        if target.wholeMatch(of: /[a-z][a-z0-9+.-]*:.*/) != nil, !FileManager.default.fileExists(atPath: path) {
            return target
        }   // Tab URIs such as session:, diff:, ext:…
        return path
    }

    /// Opens `target` in the editor area of the workspace that contains `cwd` (when there is one).
    /// `focus` brings Kelp to the front and switches to that workspace. Otherwise the tab waits there quietly.
    public static func open(_ target: String, split: String?, cwd: String, focus: Bool = false, client: RPCClient)
        async throws -> Delivered
    {
        let all = try await client.call(WorktreeList()), own = try await ownWorkspace(client: client)
        // A file that is in no workspace opens in the caller's own workspace, where an agent's tab is held. When the
        // caller has no workspace, it opens in the workspace on screen.
        let id = workspace(cwd: cwd, among: all, own: own)?.id ?? own
        return try await client.call(
            UIOpen(uri: uri(for: target, cwd: cwd), split: split, focus: focus ? true : nil, worktreeId: id))
    }

    /// Returns the workspace that a command run in `cwd` refers to (`workspace(cwd:among:own:)`), using the daemon's
    /// lists.
    public static func workspace(
        cwd: String, session: String? = ProcessInfo.processInfo.environment["KELP_SESSION"],
        client: RPCClient
    ) async throws -> Worktree? {
        let all = try await client.call(WorktreeList())
        return workspace(cwd: cwd, among: all, own: try await ownWorkspace(session: session, client: client))
    }

    /// Returns the workspace of the session this process runs in (the one KELP_SESSION names).
    static func ownWorkspace(
        session: String? = ProcessInfo.processInfo.environment["KELP_SESSION"], client: RPCClient
    ) async throws -> String? {
        session == nil ? nil : try await client.call(SessionList()).first { $0.id == session }?.worktreeId
    }

    /// Returns the workspace that holds `cwd`. A project's workspaces share its folder, so the folder alone can't tell
    /// them apart. The agent's own workspace (`own`, from KELP_SESSION) wins when it holds `cwd`. Otherwise the deepest
    /// workspace that holds it wins, so a worktree inside the project's folder (`.claude/worktrees/x`) beats the
    /// project. Among workspaces that share that folder, the first one wins.
    public static func workspace(cwd: String, among all: [Worktree], own: String?) -> Worktree? {
        let here = all.filter { Paths.inside(cwd, $0.path) }
        return here.first { $0.id == own } ?? here.max { $0.path.count < $1.path.count }
    }

    static func absolute(_ path: String, cwd: String) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
    }
}
