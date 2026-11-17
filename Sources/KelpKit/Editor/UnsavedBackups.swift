import Core
import WorkbenchKit

/// The unsaved text that the file tabs' `UnsavedBackup` left in the store, looked at after a launch. Each entry is
/// [uri, workspace, text] under `prefix`.
@MainActor
enum UnsavedBackups {
    static let prefix = "backup."   // BuiltinFiles writes it: `UnsavedBackup.prefix`

    /// Reopens the backed-up files after a launch. A crash can come before the layout was saved, and then no tab would
    /// ask for what was kept, so each backup gets a tab in its workspace. Tabs are built when shown, and that's when
    /// the text comes back. A workspace counts as gone only by the daemon's own list, because one that didn't load (a
    /// slow daemon) mustn't take the text along. A gone workspace already asked its question, but a file whose save
    /// failed then is still here, so it moves to a workspace that holds the file. A backup no workspace holds is
    /// dropped.
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
                guard TabURI.scheme(parts[0]) == "file",
                    let holder = app.worktree(holding: TabURI.filePath(parts[0]).path)?.id
                else { continue }
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
}
