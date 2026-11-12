import AppKit
import Core
import KelpKit
import WorkbenchKit

/// A language server as Settings › Languages and a file's own list show it.
enum ServerStatus: Equatable {
    case unknown, missing, installing, installed, running(files: Int), failed
    /// Installed, in a project that isn't trusted to run it yet.
    case untrusted
}

// What's installed and running: asked of the daemon while someone looks (Settings › Languages, a file's list), and
// after an install was started.
extension LSPManager {
    /// The project on screen.
    var projectRoot: String? { app.worktree(app.workbench.workspaceId)?.path }

    /// Every server command the languages name, asked about for `root`.
    func refresh(_ root: String?) async {
        let commands = Set(app.extensions.all.languages.flatMap(\.allServers).map(\.command)).sorted()
        guard let found = await app.quiet(LSPServers(root: root, commands: commands)) else { return }
        heard(found, of: root)
    }

    /// `server` as it is in `root` (nil: on this Mac, in no project). `asks`: it's one of the project's own languages,
    /// so a project not trusted yet is what holds it.
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

    /// The languages `worktree` has files of, read once per look at the page.
    func scan(_ worktree: Worktree) async {
        guard let files = await app.quiet(FilesList(id: worktree.id)) else { return }
        used[worktree.path] = LanguageRows.used(app.extensions.all.languages, in: files)
    }

    /// An install's terminal ended: the login shell's PATH is read again (an installer may have added its folder), and
    /// the daemon says what's there now.
    func installEnded(_ command: String) async {
        _ = await app.quiet(ProcessRefreshPath(), timeout: 30)
        await refresh(projectRoot)
        gaveUp(on: command)   // there or not: no longer "Installing…"
    }
}
