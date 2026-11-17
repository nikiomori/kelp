import Core
import Foundation

// run.detect lists what a workspace offers to run, read where its files are, and run.start starts one of those.

extension Workspaces {
    /// Returns what the workspace's files offer to run, read where the files are. For a remote project that means on
    /// its host, through the host's shell over the shared connection, so the host's PATH applies (with nvm or pyenv).
    func runOptions(_ worktree: Worktree) throws -> [RunOption] {
        let out: Data
        if let remote = remotes.of(worktree.path) {
            out = try Subprocess.output(
                [remotes.ssh] + remote.sshArgs(tty: false) + [remote.command(["sh", "-c", Runnables.script])],
                cwd: NSHomeDirectory())
        } else {
            out = try Subprocess.output(
                ["/bin/sh", "-c", Runnables.script], cwd: worktree.path, env: ["PATH": Sessions.childPath])
        }
        return Runnables.options(Runnables.parse(String(decoding: out, as: UTF8.self)))
    }
}

extension RunDetect: Handled {
    static let agents = AgentAccess.reads
    func handle(_ workspaces: Workspaces) throws -> Result {
        let options = try workspaces.runOptions(try workspaces.store.worktree(named: worktreeId))
        return Result(options: options, guess: Runnables.guess(options))
    }
}

extension RunStart: Handled {
    /// Starts the option as the files describe it now, not a command the caller sends, so what runs is what the list
    /// showed. A remote
    /// project's run goes in tmux on the host, so a dropped connection leaves the server running.
    func handle(_ workspaces: Workspaces) throws -> Session {
        let worktree = try workspaces.store.worktree(named: worktreeId)
        guard let option = try workspaces.runOptions(worktree).first(where: { $0.id == id }) else {
            throw RPCError.invalidParams(
                "“\(id.split(separator: "|").last ?? "")” is no longer in the project's files.")
        }
        var launch = Sessions.Launch()
        launch.title =
            option.folder.isEmpty ? option.name : "\((option.folder as NSString).lastPathComponent) › \(option.name)"
        launch.openURLs = true
        launch.onHostInTmux = true
        (launch.cols, launch.rows) = Sessions.Launch.size(cols: cols, rows: rows)
        let command =
            option.folder.isEmpty ? option.command : "cd \(ShellQuote.word(option.folder)) && \(option.command)"
        return try workspaces.sessions.spawn(
            cwd: worktree.path, manifest: .custom(command), worktreeId: worktree.id, launch)
    }
}

extension Methods {
    static let runMethods: [any Answered.Type] = [RunDetect.self, RunStart.self]
}
