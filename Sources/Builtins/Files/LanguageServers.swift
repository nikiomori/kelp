import AppKit
import Core
import KelpKit
import WorkbenchKit

/// The state of a language server, as Settings › Languages and a file's own server list show it.
enum ServerStatus: Equatable {
    case unknown, missing, installing, installed, running(files: Int), failed
    /// Installed, in a project that isn't trusted to run it yet.
    case untrusted
}

// Finds out which servers are installed and running. The daemon is asked while someone looks (Settings › Languages, a
// file's server list), and after an install.
extension LSPManager {
    /// The folder of the project on screen.
    var projectRoot: String? { app.worktree(app.workbench.workspaceId)?.path }

    /// Asks the daemon about every server command the languages name, for the project at `root`.
    func refresh(_ root: String?) async {
        let commands = Set(app.extensions.all.languages.flatMap(\.allServers).map(\.command)).sorted()
        guard let found = await app.quiet(LSPServers(root: root, commands: commands)) else { return }
        heard(found, of: root)
    }

    /// Returns the status of `server` in `root` (nil means on this Mac, in no project). Pass `asks` when the server is
    /// for one of the project's own languages, so that a project not trusted yet shows as what holds the server back.
    func status(_ server: LanguageSpec.Server, in root: String?, asks: Bool = false) -> ServerStatus {
        if installing.contains(server.command) { return .installing }
        guard let state = states[root ?? ""]?[server.command] else { return .unknown }
        if !state.installed { return .missing }
        if state.running { return .running(files: state.files) }
        if state.failed { return .failed }
        if asks, let root, enabled(), !trusted(root) { return .untrusted }
        return .installed
    }

    func restart(_ server: LanguageSpec.Server, in root: String) async {
        guard await app.call(LSPRestart(root: root, command: server.command)) != nil else { return }
        await refresh(root)
    }

    /// Finds the languages that `worktree` has files of. It runs once each time the page shows.
    func scan(_ worktree: Worktree) async {
        guard let files = await app.quiet(FilesList(id: worktree.id)) else { return }
        used[worktree.path] = LanguageRows.used(app.extensions.all.languages, in: files)
    }

    /// Called when an install's terminal ends. The login shell's PATH is read again (an installer may have added its
    /// folder), and the daemon says which servers are there now.
    func installEnded(_ command: String) async {
        _ = await app.quiet(ProcessRefreshPath(), timeout: 30)
        await refresh(projectRoot)
        gaveUp(on: command)   // installed or not, the server no longer shows "Installing…"
    }
}
