import Core
import Foundation

extension Sessions {
    /// A turn of `session` ended: the pages it made in its workspace keep how the turn left them, named by its prompt.
    /// On this Mac only: a remote project's folder here holds only its marker.
    func keepArtifactVersions(session: String, worktree: String?, prompt: String) {
        Log.store.attempt("keeping the versions of \(session)'s artifacts") {
            guard let workspace = try store.worktree(worktree ?? ""), remotes.of(workspace.path) == nil,
                FileManager.default.fileExists(atPath: Artifacts.dir(root: workspace.path).path)
            else { return }
            try Artifacts.keepVersions(root: workspace.path, session: session, label: prompt)
        }
    }
}

extension ArtifactNew: Handled {
    static var quick: Bool { true }
    func handle(_ workspaces: Workspaces) throws -> String {
        let root = try artifactsRoot(workspaces.store, cwd: cwd, session: session)
        return try Artifacts.create(kind, title: title, root: root, session: session).path
    }
}

extension ArtifactAdd: Handled {
    /// An agent's hook waits for it.
    static var quick: Bool { true }
    func handle(_ workspaces: Workspaces) throws -> Bool {
        guard url.hasPrefix("https://") else { throw RPCError.invalidParams("a page's link starts with https://") }
        let root = try artifactsRoot(workspaces.store, cwd: cwd, session: session)
        return try Artifacts.addNative(url: url, title: title, type: type, root: root, session: session, page: page)
            != nil
    }
}

extension Methods {
    static let artifactMethods: [any Handled.Type] = [ArtifactNew.self, ArtifactAdd.self]
}

/// The folder whose artifacts a command run in `cwd` means: the workspace that holds it (`session`'s own first, as
/// `IDE.workspace` picks), else `cwd` itself: a chat outside any project.
private func artifactsRoot(_ store: Store, cwd: String, session: String?) throws -> String {
    var isFolder: ObjCBool = false
    guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue
    else { throw RPCError.invalidParams("not a folder: \(cwd)") }
    let own = try session.flatMap { try store.session($0) }?.worktreeId
    return IDE.workspace(cwd: cwd, among: try store.worktrees().filter { !$0.archived }, own: own)?.path ?? cwd
}
