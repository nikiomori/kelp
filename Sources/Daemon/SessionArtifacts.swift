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
