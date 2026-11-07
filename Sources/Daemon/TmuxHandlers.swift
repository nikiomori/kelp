import Core
import Foundation

/// tmux where a workspace's sessions run: on this Mac, or on a remote project's host (see `Tmux`).
extension Sessions {
    /// `tmux <args>`, on the host for a remote project through its login shell, as its terminals are (tmux is on that PATH).
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

    /// The tmux session it runs in: a remote agent's on the host, or the one a terminal attaches to.
    static func tmuxName(_ session: Session) -> String? { session.tmux ?? Tmux.session(session.argv) }

    /// Ends the tmux session a session of Kelp's own ran in, in the background (over ssh it can take a while).
    func endOwnTmux(_ session: Session) {
        guard let name = Self.tmuxName(session), Tmux.isOwn(name) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            Log.session.attempt("ending tmux session \(name)") {
                try tmux(["kill-session", "-t", "=" + name], cwd: session.cwd)
            }
        }
    }

    /// The first program running in the session's panes other than their shells.
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
