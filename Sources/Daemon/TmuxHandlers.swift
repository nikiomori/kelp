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
        let r = try Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, timeLimit: timeLimit)
        guard !r.truncated else {
            throw RPCError.internalError(
                "tmux printed more than \(Subprocess.outputLimit >> 20) MB, more than Kelp reads.")
        }
        return r
    }

    /// The tmux session it runs in: a remote agent's on the host, or the one a terminal attaches to.
    static func tmuxName(_ s: Session) -> String? { s.tmux ?? Tmux.session(s.argv) }

    /// Ends the tmux session a session of Kelp's own ran in, in the background (over ssh it can take a while).
    func endOwnTmux(_ s: Session) {
        guard let name = Self.tmuxName(s), Tmux.isOwn(name) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            Log.session.attempt("ending tmux session \(name)") {
                try tmux(["kill-session", "-t", "=" + name], cwd: s.cwd)
            }
        }
    }

    /// The first program running in the session's panes other than their shells.
    func tmuxBusy(_ name: String, cwd: String) -> String? {
        guard
            let r = try? tmux(
                ["list-panes", "-s", "-t", "=" + name, "-F", "#{pane_current_command}"], cwd: cwd, timeLimit: 2),
            r.status == 0
        else { return nil }
        return String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).first {
            !Tmux.shells.contains($0)
        }
    }
}

extension TmuxList: Handled {
    func handle(_ sessions: Sessions) throws -> Result {
        let r = try sessions.tmux(
            ["list-sessions", "-F", Tmux.format], cwd: sessions.store.worktree(named: worktreeId).path)
        let err = String(decoding: r.stderr, as: UTF8.self)
        if r.status == 0 { return Tmux.parse(String(decoding: r.stdout, as: UTF8.self)) }
        if Tmux.noServer(err) { return [] }
        let why = err.trimmingCharacters(in: .whitespacesAndNewlines)
        throw RPCError.invalidParams(
            r.timedOut
                ? "tmux didn't answer." : why.isEmpty ? "tmux list-sessions failed (exit code \(r.status))." : why)
    }
}
