import Foundation
import Core

/// Who a call comes from (`Caller`), by the process on the connection: what `Daemon.allow` lets it do goes by this.
/// The user's only when Kelp can tell: Kelp's window, a terminal of Kelp's no agent is on the line of, a program started
/// under an app (Terminal, iTerm, an editor's terminal). Anything else is held to an agent's rules: a program that left
/// every terminal and app behind (a double fork with `setsid`, `script`, a tmux server with no one attached) is what an
/// agent does to pass for the user.
extension Sessions {
    /// What a session started by `Caller.kelpd` records as its origin, and so its line (`lineage`): one that breaks off.
    static let ownProgram = "kelpd"
    /// The same for `Caller.unknown`, and for `Caller.detached`.
    static let unknown = "unknown", detached = "detached"

    /// The live session whose program `pid` is, or runs under (its own child, a shell's job…); `kelpd` for one this
    /// daemon started. One that left its tree (a double fork, `nohup … &`) still has its session's terminal as its own;
    /// one of the daemon's that did is still in the daemon's process session (kelpd leads its own: kelpd/main.swift); one
    /// in a tmux pane is whoever is attached to that tmux session (`tmuxCaller`).
    func session(running pid: pid_t, throughTmux: Bool = true) -> Caller {
        guard pid == getpid() || Subprocess.parent(pid) != nil else { return .unknown }
        guard pid != getpid() else { return .user }
        let mine = Dictionary(live.all.map { ($0.pty.pid, $0.snapshot.id) }) { a, _ in a }
        let strict = strictCallers.withLock { $0 }
        var p = pid, chain: [pid_t] = []
        for _ in 0..<64 {
            if let id = mine[p] { return .session(id) }
            // Under kelpd but in none of its sessions: its own (a test's in-process daemon is the test, whose programs are the user's).
            if Subprocess.isRunning(p) || strict && p == getpid() { return .kelpd }
            chain.append(p)
            guard let up = Subprocess.parent(p), up > 1, up != p else { break }
            p = up
        }
        if let tty = Subprocess.terminal(pid), let s = live.all.first(where: { Subprocess.terminal($0.pty.pid) == tty }) {
            return .session(s.snapshot.id)
        }
        let daemon = getsid(0)   // a test's in-process daemon leads no session: then none of this
        if daemon == getpid(), getsid(pid) == daemon { return .kelpd }
        let programs = chain.map { Unix.executable($0) ?? "" }
        if throughTmux, programs.last.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "tmux", let c = tmuxCaller(pid) { return c }
        guard strict else { return .user }
        return programs.contains(where: Self.isApp) ? .user : .detached
    }

    /// Who is attached to the tmux session whose pane `pid` runs in: a terminal of Kelp's (that session, agent rules and
    /// all, which outweighs any other client), else an app's terminal (the user); nil for none attached, or no tmux to ask.
    private func tmuxCaller(_ pid: pid_t) -> Caller? {
        guard let dev = Subprocess.terminal(pid), let tty = devname(dev_t(dev), S_IFCHR).map({ "/dev/" + String(cString: $0) }) else { return nil }
        func lines(_ args: [String]) -> [[Substring]] {
            // The same server the user's and Kelp's terminals reach: its socket folder as theirs (TMUX_TMPDIR, tests too).
            var env = ["PATH": Self.childPath]
            env["TMUX_TMPDIR"] = ProcessInfo.processInfo.environment["TMUX_TMPDIR"]
            do {
                let r = try Subprocess.run([try LoginPath.resolve("tmux")] + args, cwd: NSHomeDirectory(), env: env, timeLimit: 2)
                guard r.status == 0 else { return [] }
                return String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.split(separator: " ", maxSplits: 1) }
            } catch {
                Log.session.info("asking tmux who a caller is: \(error)")
                return []
            }
        }
        guard let name = lines(["list-panes", "-a", "-F", "#{pane_tty} #{session_name}"]).first(where: { $0.first.map(String.init) == tty })?.last
        else { return nil }
        let clients = lines(["list-clients", "-t", "=" + name, "-F", "#{client_pid} #{session_name}"]).compactMap { $0.first.flatMap { pid_t($0) } }
        let seen = clients.map { session(running: $0, throughTmux: false) }
        return seen.first { if case .session = $0 { true } else { false } } ?? (seen.contains(.user) ? .user : nil)
    }

    /// An app's own program (inside a bundle's Contents/MacOS), which launchd started for the user, not a daemon.
    private static func isApp(_ path: String) -> Bool { path.contains(".app/Contents/MacOS/") }

    /// Who the program on `conn` is: its process tree, looked up once per connection (`Connection.owner`), as it connects
    /// (Daemon.serve), while it's surely there. The daemon's own calls (`conn` -1) are the user's, and Kelp's window,
    /// which launchd starts with no terminal; a connection gone already is `kelpd`'s, one whose program can't be read `unknown`.
    func caller(_ conn: Int) -> Caller {
        guard let c = clients.connection(conn) else { return conn < 0 ? .user : .kelpd }
        if let known = c.owner.withLock({ $0 }) { return known }
        let seen = c.peerPID.map { session(running: $0) } ?? .unknown   // not under the connection's lock: this takes the sessions'
        let found: Caller = seen == .detached && c.peer == Clients.appExecutable ? .user : seen
        c.owner.withLock { $0 = found }
        return found
    }
}
