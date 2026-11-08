import Core
import WorkbenchKit

/// What the file tabs' `UnsavedBackup` left in the store, looked at after a launch: [uri, workspace, text] under `prefix`.
@MainActor
enum UnsavedBackups {
    static let prefix = "backup."   // BuiltinFiles writes it: `UnsavedBackup.prefix`

    /// After a launch. A crash can come before the layout was saved, and then no tab would ask for what was kept: each gets
    /// one, in its workspace. Tabs are built when shown, and that's when the text comes back. A workspace gone (by the daemon's
    /// own list: one that didn't load, a slow daemon, mustn't take the text along) asked its question, but a file whose save
    /// failed then is still here: it goes to a workspace that holds the file. What no workspace holds goes.
    static func reopen(_ app: AppModel, in host: EditorHost?) async {
        var found = 0
        let known = await app.quiet(WorktreeList()).map { Set($0.map(\.id)) }
        for (key, value) in app.uiState.all(prefix: prefix) {
            let parts = value.array?.compactMap(\.string) ?? []
            guard parts.count == 3 else {
                app.uiState[key] = nil
                continue
            }
            var workspace = parts[1]
            if app.worktree(workspace) == nil {
                guard let known, !known.contains(workspace) else { continue }
                app.uiState[key] = nil
                guard let holder = holder(of: parts[0], in: app.worktrees) else { continue }
                workspace = holder
                let moved = prefix + workspace + "." + parts[0]   // one typed there since is newer
                if app.uiState[moved] == nil {
                    app.uiState[moved] = .array([.string(parts[0]), .string(workspace), .string(parts[2])])
                }
            }
            host?.openInBackground(parts[0], workspace: workspace)
            found += 1
        }
        if found > 0 { Banner.show(String(localized: "Unsaved changes came back after a crash: \(found)")) }
    }

    /// The workspace whose folder holds a file tab's file (the innermost: a branch's folder inside its project's).
    static func holder(of uri: String, in worktrees: [Worktree]) -> String? {
        guard TabURI.scheme(uri) == "file" else { return nil }
        let path = TabURI.filePath(uri).path
        return worktrees.filter { IDE.inside(path, $0.path) }.max { $0.path.count < $1.path.count }?.id
    }
}
