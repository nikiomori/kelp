import Core
import Foundation
import GitKit

// run.detect and run.start: what a workspace offers to run, read where its files are, and starting one.

extension Workspaces {
    /// What the workspace's files offer to run, read where they are: on a remote project's host, through its shell (its
    /// PATH: nvm, pyenv), over the shared connection.
    func runOptions(_ worktree: Worktree) throws -> [RunOption] {
        let out: String
        if let remote = remotes.of(worktree.path) {
            out = try Git.run(
                remote.sshArgs(tty: false) + [remote.command(["sh", "-c", Runnables.script])], cwd: NSHomeDirectory(),
                executable: remotes.ssh)
        } else {
            out = try Git.run(
                ["-c", Runnables.script], cwd: worktree.path, executable: "/bin/sh", env: ["PATH": Sessions.childPath])
        }
        return Runnables.options(Runnables.parse(out))
    }
}

extension RunDetect: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        let options = try workspaces.runOptions(try workspaces.store.worktree(named: worktreeId))
        return Result(options: options, guess: Runnables.guess(options))
    }
}

extension RunStart: Handled {
    /// The option as the files say now, not a command the caller sends: what runs is what the list showed. A remote
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
        let command =
            option.folder.isEmpty ? option.command : "cd \(ShellQuote.word(option.folder)) && \(option.command)"
        return try workspaces.sessions.spawn(
            cwd: worktree.path, manifest: .custom(command), worktreeId: worktree.id, launch)
    }
}
