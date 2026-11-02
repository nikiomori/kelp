import Core

/// What the file tabs' `UnsavedBackup` left in the store, looked at after a launch: [uri, workspace, text] under `prefix`.
@MainActor
enum UnsavedBackups {
    static let prefix = "backup."   // BuiltinFiles writes it: `UnsavedBackup.prefix`

    /// After a launch. A crash can come before the layout was saved, and then no tab would ask for what was kept: each gets
    /// one, in its workspace. Tabs are built when shown, and that's when the text comes back. A workspace gone was closed with
    /// its question asked.
    static func reopen(_ app: AppModel, in host: EditorHost?) {
        var found = 0
        for (key, value) in app.uiState.all(prefix: prefix) {
            let parts = value.array?.compactMap(\.string) ?? []
            guard parts.count == 3, app.worktree(parts[1]) != nil else {
                app.uiState[key] = nil
                continue
            }
            host?.openInBackground(parts[0], workspace: parts[1])
            found += 1
        }
        if found > 0 { Banner.show(String(localized: "Unsaved changes came back after a crash: \(found)")) }
    }
}
