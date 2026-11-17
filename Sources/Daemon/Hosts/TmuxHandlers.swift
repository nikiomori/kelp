import Core
import Foundation

/// Runs tmux where a workspace's sessions run, on this Mac or on a remote project's host (see `Tmux`).
extension Sessions {
    /// Runs `tmux <args>`. For a remote project it runs on the host through the login shell, as the project's terminals
    /// do, because tmux is on that PATH.
    func tmux(_ args: [String], cwd: String, timeLimit: TimeInterval = 30) throws -> Subprocess.Output {
        let argv =
            try remotes.of(cwd).map { [$0.ssh] + $0.sshArgs(tty: false) + [$0.command(["tmux"] + args)] }
            ?? [LoginPath.resolve("tmux")] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.childPath
        let output = try Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, timeLimit: timeLimit)
        guard !output.truncated else {
            throw RPCError.internalError(
                "tmux printed more than \(Subprocess.outputLimit >> 20) MB, more than Kelp reads.")
        }
        return output
    }

    /// Returns the name of the tmux session that a session runs in: a remote agent's tmux session on the host, or the
    /// one a terminal attaches to.
    static func tmuxName(_ session: Session) -> String? { session.tmux ?? Tmux.session(session.argv) }

    /// Ends the tmux session that the session ran in, when Kelp made that tmux session. It runs in the background,
    /// because over ssh it can take a while.
    func endOwnTmux(_ session: Session) {
        guard let name = Self.tmuxName(session), Tmux.isOwn(name) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            Log.session.attempt("ending tmux session \(name)") {
                try tmux(["kill-session", "-t", "=" + name], cwd: session.cwd)
            }
        }
    }

    /// Returns the first program, other than a shell, that runs in the panes of tmux session `name`.
    func tmuxBusy(_ name: String, cwd: String) -> String? {
        guard
            let output = try? tmux(
                ["list-panes", "-s", "-t", "=" + name, "-F", "#{pane_current_command}"], cwd: cwd, timeLimit: 2),
            output.status == 0
        else { return nil }
        return String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).first
        {
            !Tmux.shells.contains($0)
        }
    }
}

extension TmuxList: Handled {
    static let agents = AgentAccess.reads
    func handle(_ sessions: Sessions) throws -> Result {
        let output = try sessions.tmux(
            ["list-sessions", "-F", Tmux.format], cwd: sessions.store.worktree(named: worktreeId).path)
        let err = String(decoding: output.stderr, as: UTF8.self)
        if output.status == 0 { return Tmux.parse(String(decoding: output.stdout, as: UTF8.self)) }
        if Tmux.noServer(err) { return [] }
        let why = err.trimmingCharacters(in: .whitespacesAndNewlines)
        throw RPCError.invalidParams(
            output.timedOut
                ? "tmux didn't answer." : why.isEmpty ? "tmux list-sessions failed (exit code \(output.status))." : why)
    }
}

extension Methods {
    static let tmuxMethods: [any Answered.Type] = [TmuxList.self]
}
