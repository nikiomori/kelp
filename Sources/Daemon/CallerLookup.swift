import Foundation
import Core

/// Who a call comes from (`Caller`), by the process on the connection: what `Daemon.allow` lets it do goes by this.
/// The user's when Kelp can tell it's theirs: Kelp's window and its terminals, a terminal of Kelp's no agent is on the line
/// of, or a program that came from a system service (an ancestor of another account that isn't a setuid program: `sshd`,
/// cron) or from an app that isn't a Kelp (Terminal, iTerm, an editor). Anything else is held to an agent's rules: a
/// program that left its terminal and every such ancestor behind (a double fork with `setsid`, `script` in the
/// background, `tmux new -d`, a launchd job). This fences an agent's slips and one steered into such a command; one set on
/// getting around it can (a cron line of its own, a bundle of its own, an app it starts): docs/architecture.md.
extension Sessions {
    /// What a session started by `Caller.kelpd` records as its origin, and so its line (`lineage`): one that breaks off.
    static let ownProgram = "kelpd"
    /// The same for `Caller.unknown`, and for `Caller.detached`.
    static let unknown = "unknown", detached = "detached"

    /// The live session whose program `pid` is, or runs under (its own child, a shell's job…), or whose terminal it or
    /// one of its parents has (a double fork, `nohup`, `script`); `kelpd` for one this daemon started (kelpd leads its
    /// own process session: kelpd/main.swift); one in a tmux pane is whoever is attached there (`tmuxCaller`).
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
        let ttys = Set(chain.compactMap(Subprocess.terminal))
        if let s = live.all.first(where: { Subprocess.terminal($0.pty.pid).map(ttys.contains) == true }) { return .session(s.snapshot.id) }
        let daemon = getsid(0)   // a test's in-process daemon leads no session: then none of this
        if daemon == getpid(), getsid(pid) == daemon { return .kelpd }
        if throughTmux, let server = chain.last, Unix.executable(server).map({ URL(fileURLWithPath: $0).lastPathComponent }) == "tmux" {
            return tmuxCaller(pid, server: server) ?? .detached
        }
        guard strict else { return .user }
        return chain.dropFirst().contains { Self.cameFromTheUser($0) } ? .user : .detached
    }

    /// An ancestor that only the user's own login or an app starts: Kelp's window (its terminals' `kelp attach`), one of
    /// another account that isn't a setuid program anyone may run (`sshd`, cron; not `login`, `su`, `sudo`), or an app's
    /// own program that isn't a Kelp's (this one's, or another install's: a bundle with a kelpd in it).
    static func cameFromTheUser(_ pid: pid_t) -> Bool {
        let path = Unix.executable(pid)
        if path == Clients.appExecutable { return true }
        if let uid = Subprocess.owner(pid), uid != getuid(), let path, !Self.isSetuid(path) { return true }
        guard let path, let r = path.range(of: ".app/Contents/MacOS/") else { return false }
        let folder = String(path[..<r.upperBound])
        return !path.hasPrefix(kelpsOwn) && !FileManager.default.fileExists(atPath: folder + "kelpd")
    }

    /// A program that runs as its owner whoever starts it (`login`, `su`, `sudo`): another account's process, but one
    /// any program of the user's can have as its parent.
    private static func isSetuid(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && st.st_mode & S_ISUID != 0
    }

    /// Where Kelp's own programs are (kelp, kelpd, Kelp Machine): its bundle, else (a build folder) kelpd's folder.
    private static let kelpsOwn: String = {
        let me = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        if let r = me.range(of: ".app/Contents/") { return String(me[..<r.lowerBound]) + ".app/" }
        return URL(fileURLWithPath: me).deletingLastPathComponent().path + "/"
    }()

    /// Who is attached to the tmux session and window whose pane `pid` runs in: a terminal of Kelp's (that session, with
    /// its agent rules, outweighing any other client), else the user's own (theirs only for the pane they look at: the
    /// active one of the window shown, not one an agent added out of sight); nil for nobody, or no tmux to ask. Asked
    /// once a pane and 10 s (`tmuxAnswers`): a hook comes from the same pane many times a turn.
    private func tmuxCaller(_ pid: pid_t, server: pid_t) -> Caller? {
        guard let dev = Subprocess.terminal(pid), let tty = devname(dev_t(dev), S_IFCHR).map({ "/dev/" + String(cString: $0) }) else { return nil }
        // Kept only for a caller that was there before it: a terminal's name is given to the next pane once one closes.
        if let kept = tmuxAnswers.withLock({ $0[tty] }), kept.at.timeIntervalSinceNow > -10,
           let born = Subprocess.started(pid), Double(born) / 1e6 < kept.at.timeIntervalSince1970 { return kept.caller }
        let socket = Self.tmuxSocket(Subprocess.arguments(server) ?? [])
        func lines(_ args: [String]) -> [[Substring]] {
            // The server that pane is on: its socket as it was started with (-L, -S), else the default one (TMUX_TMPDIR).
            var env = ["PATH": Self.childPath]
            env["TMUX_TMPDIR"] = ProcessInfo.processInfo.environment["TMUX_TMPDIR"]
            do {
                let r = try Subprocess.run([try LoginPath.resolve("tmux")] + socket + args, cwd: NSHomeDirectory(), env: env, timeLimit: 2)
                guard r.status == 0 else { return [] }
                // The session's name last, whole: it may hold spaces.
                return String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.split(separator: " ", maxSplits: 3) }
            } catch {
                Log.session.info("asking tmux who a caller is: \(error)")
                return []
            }
        }
        let format = "#{pane_tty} #{pane_active} #{window_active} #{session_name}"
        guard let pane = lines(["list-panes", "-a", "-F", format]).first(where: { $0.first.map(String.init) == tty }), pane.count == 4 else {
            return nil
        }
        let shown = pane[1] == "1" && pane[2] == "1"
        let clients = lines(["list-clients", "-t", "=" + pane[3], "-F", "#{client_pid}"]).compactMap { $0.first.flatMap { pid_t($0) } }
        let found = Self.tmuxDecision(clients.map { session(running: $0, throughTmux: false) }, shown: shown)
        tmuxAnswers.withLock { $0[tty] = (found, Date()) }
        return found
    }

    /// A pane's caller from who's attached: a Kelp terminal's session (agent rules and all) outweighs any other client;
    /// else the user's, for the pane shown to them only; else nobody's.
    static func tmuxDecision(_ attached: [Caller], shown: Bool) -> Caller? {
        attached.first { if case .session = $0 { true } else { false } } ?? (shown && attached.contains(.user) ? .user : nil)
    }

    /// The `-L name` or `-S path` a tmux server was started with, for asking that server.
    static func tmuxSocket(_ argv: [String]) -> [String] {
        guard let i = argv.firstIndex(where: { $0 == "-L" || $0 == "-S" }), i + 1 < argv.count else { return [] }
        return [argv[i], argv[i + 1]]
    }

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
