import Core

/// What the file tabs' `UnsavedBackup` left in the store, looked at after a launch: [uri, workspace, text] under `prefix`.
@MainActor
enum UnsavedBackups {
    static let prefix = "backup."   // BuiltinFiles writes it: `UnsavedBackup.prefix`

    /// After a launch. A crash can come before the layout was saved, and then no tab would ask for what was kept: each gets
    /// one, in its workspace. Tabs are built when shown, and that's when the text comes back. A workspace gone was closed with
    /// its question asked; gone by the daemon's own list, as one that didn't load (a slow daemon) mustn't take the text along.
    static func reopen(_ app: AppModel, in host: EditorHost?) async {
        var found = 0
        let known = await app.quiet(WorktreeList()).map { Set($0.map(\.id)) }
        for (key, value) in app.uiState.all(prefix: prefix) {
            let parts = value.array?.compactMap(\.string) ?? []
            guard parts.count == 3 else {
                app.uiState[key] = nil
                continue
            }
            guard app.worktree(parts[1]) != nil else {
                if let known, !known.contains(parts[1]) { app.uiState[key] = nil }
                continue
            }
            host?.openInBackground(parts[0], workspace: parts[1])
            found += 1
        }
        if found > 0 { Banner.show(String(localized: "Unsaved changes came back after a crash: \(found)")) }
    }
}
