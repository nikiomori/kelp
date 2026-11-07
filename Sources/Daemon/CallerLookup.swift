import Foundation
import os
import Core
import Agents

/// Who a call comes from (`Caller`), by the process on the connection: what `Daemon.allow` lets it do goes by this.
/// The user's when Kelp can tell it's theirs: Kelp's window and its terminals, a terminal of Kelp's no agent is on the line
/// of, or a program that came from a system service (an ancestor of another account that isn't a setuid program: `sshd`,
/// cron) or from an app that isn't a Kelp (Terminal, iTerm, an editor). Anything else is held to an agent's rules: a
/// program that left its terminal and every such ancestor behind (a double fork with `setsid`, `script` in the
/// background, `tmux new -d`, a launchd job), and whatever runs under a known agent's program, one the user typed in by
/// hand included (`Caller.typedAgent`). This fences an agent's slips and one steered into such a command; one set on
/// getting around it can (a cron line of its own, a bundle of its own, an app it starts): docs/architecture.md.
extension Sessions {
    /// What a session started by `Caller.kelpd` records as its origin, and so its line (`lineage`): one that breaks off.
    static let ownProgram = "kelpd"
    /// The same for `Caller.unknown`, and for `Caller.detached`.
    static let unknown = "unknown", detached = "detached"
}

/// Who calls (`Caller`), by the process on each connection: the daemon's one place that tells, apart from the sessions
/// it reads from (their programs, their terminals).
final class Callers: Sendable {
    private let live: SessionTable, clients: Clients
    /// Whether a caller has to be known for the user's to count as theirs: kelpd says so as it starts (`Daemon.strict`).
    /// A test's in-process daemon doesn't, and its test process calls as the user.
    let strict = OSAllocatedUnfairLock(initialState: false)
    /// Who a tmux pane's caller is, by the pane's terminal, for 10 s (`tmuxCaller`).
    private let tmuxAnswers = OSAllocatedUnfairLock<[String: (caller: Caller?, at: Date)]>(initialState: [:])

    init(live: SessionTable, clients: Clients) { self.live = live; self.clients = clients }

    /// The live session whose program `pid` is, or runs under (its own child, a shell's job…), or whose terminal it or
    /// one of its parents has (a double fork, `nohup`, `script`); `kelpd` for one this daemon started (kelpd leads its
    /// own process session: kelpd/main.swift); one in a tmux pane is whoever is attached there (`tmuxCaller`).
    func session(running pid: pid_t, throughTmux: Bool = true) -> Caller {
        guard pid == getpid() || Subprocess.parent(pid) != nil else { return .unknown }
        guard pid != getpid() else { return .user }
        let all = live.all
        let mine = Dictionary(all.map { ($0.pty.pid, $0.snapshot.id) }) { a, _ in a }
        let agents = Set(all.filter { $0.snapshot.isAgent }.map(\.snapshot.id))
        let strict = self.strict.withLock { $0 }
        var p = pid, chain: [pid_t] = [], underAgent = false
        // Under an agent the user ran by hand (`claude` typed in a shell, a tmux pane, Terminal): that agent's, not theirs.
        // Not in a session Kelp started an agent in, which is that agent's already (its own programs, a wrapper's child).
        func of(_ id: String) -> Caller {
            underAgent && !agents.contains(id) ? .typedAgent(id) : .session(id)
        }
        for _ in 0..<64 {
            if let id = mine[p] { return of(id) }
            if Subprocess.isRunning(p) { return .kelpd }
            // Under kelpd but in none of its sessions: its own; what kelpd came from isn't looked at (a test's in-process
            // daemon is the test, whose programs are the user's, whatever ran the test).
            if p == getpid() { return strict ? .kelpd : underAgent ? .detached : .user }
            chain.append(p)
            if !underAgent, Self.runsAnAgent(p) { underAgent = true }
            guard let up = Subprocess.parent(p), up > 1, up != p else { break }
            p = up
        }
        let ttys = Set(chain.compactMap(Subprocess.terminal))
        if let s = all.first(where: { Subprocess.terminal($0.pty.pid).map(ttys.contains) == true }) {
            // Left its line (`&`, `nohup`: launchd its parent now) with the terminal still its own: who left it there, the
            // user or an agent typed in (gone by now, perhaps), can't be told, so it's held to an agent's rules.
            if !underAgent, chain.last.flatMap(Subprocess.parent) == 1 { underAgent = true }
            return of(s.snapshot.id)
        }
        let daemon = getsid(0)   // a test's in-process daemon leads no session: then none of this
        if daemon == getpid(), getsid(pid) == daemon { return .kelpd }
        if throughTmux, let server = chain.last, Unix.executable(server).map({ URL(fileURLWithPath: $0).lastPathComponent }) == "tmux" {
            switch tmuxCaller(pid, server: server, pane: chain.dropLast().last ?? pid) {
            case .session(let id): return of(id)
            case .user: return underAgent ? .detached : .user
            case let c?: return c
            case nil: return .detached
            }
        }
        guard strict else { return underAgent ? .detached : .user }
        return !underAgent && chain.dropFirst().contains { Self.cameFromTheUser($0) } ? .user : .detached
    }

    /// The programs of the agents Kelp knows (its presets'), by the name they're run as.
    static let agentPrograms: Set<String> = {
        Set(AgentManifest.presets.filter { !["shell", "custom"].contains($0.id) }.map { URL(fileURLWithPath: $0.command).lastPathComponent })
    }()

    /// Whether `pid` is one of those: by the name it was run as (`claude`, whose file is named for its version), or the
    /// script an interpreter runs (`node …/codex`, `python3 …/aider`).
    static func runsAnAgent(_ pid: pid_t) -> Bool {
        let agents = agentPrograms
        func interpreter(_ n: String) -> Bool { ["node", "bun", "deno", "ruby"].contains(n) || n.hasPrefix("python") }
        guard let argv = Subprocess.arguments(pid), let first = argv.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return false }
        guard interpreter(first) else { return agents.contains(first) }
        // Its script: the first word that isn't an option, a path to one anywhere (`node --require x …/codex`), or the
        // module after `-m` (`python -m aider`); not any word (`python3 bench.py --agent claude` is the user's).
        let words = Array(argv.dropFirst())
        func names(_ w: String) -> Bool { agents.contains(URL(fileURLWithPath: w).deletingPathExtension().lastPathComponent) }
        if let first = words.first(where: { !$0.hasPrefix("-") }), names(first) { return true }
        if let m = words.firstIndex(of: "-m"), m + 1 < words.count, names(words[m + 1]) { return true }
        return words.contains { $0.contains("/") && !$0.hasPrefix("-") && names($0) }
    }

    /// An ancestor that only the user's own login or an app starts: Kelp's window (its terminals' `kelp attach`), one of
    /// another account that isn't a setuid program anyone may run (`sshd`, cron; not `login`, `su`, `sudo`), or an app's
    /// own program that isn't a Kelp's (this one's, or another install's: a bundle with a kelpd in it).
    static func cameFromTheUser(_ pid: pid_t) -> Bool {
        let path = Unix.executable(pid)
        if path == Clients.appExecutable { return true }
        // iTerm's own: the server that keeps its sessions (restored ones) lives outside its bundle.
        if let path, path.hasPrefix(NSHomeDirectory() + "/Library/Application Support/iTerm2/iTermServer") { return true }
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
    private func tmuxCaller(_ pid: pid_t, server: pid_t, pane: pid_t) -> Caller? {
        guard let dev = Subprocess.terminal(pid), let tty = devname(dev_t(dev), S_IFCHR).map({ "/dev/" + String(cString: $0) }) else { return nil }
        // Kept for the pane it was asked for: one whose first program (the tmux server's child) was there before the
        // answer; a terminal's name is given to the next pane once one closes.
        if let kept = tmuxAnswers.withLock({ $0[tty] }), kept.at.timeIntervalSinceNow > -10,
           let born = Subprocess.started(pane), Double(born) / 1e6 < kept.at.timeIntervalSince1970 { return kept.caller }
        let socket = Self.tmuxSocket(Subprocess.arguments(server) ?? [])
        func lines(_ args: [String]) -> [[Substring]] {
            // The server that pane is on: its socket as it was started with (-L, -S), else the default one (TMUX_TMPDIR).
            var env = ["PATH": Sessions.childPath]
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
        let agents = Set(live.all.filter { $0.snapshot.isAgent }.map(\.snapshot.id))
        let found = Self.tmuxDecision(clients.map { session(running: $0, throughTmux: false) }, shown: shown) { agents.contains($0) }
        tmuxAnswers.withLock { $0[tty] = (found, Date()) }
        return found
    }

    /// A pane's caller from who's attached: an agent's Kelp session (its rules and all) outweighs any other client, any
    /// pane; a terminal of the user's, Kelp's or another app's, counts for the pane shown there only (not a window an
    /// agent added out of sight); else nobody's.
    static func tmuxDecision(_ attached: [Caller], shown: Bool, isAgent: (String) -> Bool = { _ in false }) -> Caller? {
        let sessions = attached.compactMap { if case .session(let id) = $0 { id } else { nil } }
        if let agent = sessions.first(where: isAgent) { return .session(agent) }
        guard shown else { return nil }
        return sessions.first.map(Caller.session) ?? (attached.contains(.user) ? .user : nil)
    }

    /// The `-L name` or `-S path` a tmux server was started with, for asking that server: among tmux's own options, before
    /// its command (`tmux new ssh -L 8080:h:80 host` names no socket), apart (`-L work`) or joined (`-Lwork`).
    static func tmuxSocket(_ argv: [String]) -> [String] {
        let valued: Set<Character> = ["c", "f", "L", "S", "T"]   // tmux's options that take a value
        var i = 1
        while i < argv.count, argv[i].hasPrefix("-"), argv[i] != "-" {
            let flags = Array(argv[i].dropFirst())
            if let at = flags.firstIndex(where: valued.contains) {
                let rest = String(flags[(at + 1)...]), value = rest.isEmpty ? (i + 1 < argv.count ? argv[i + 1] : "") : rest
                if flags[at] == "L" || flags[at] == "S" { return ["-" + String(flags[at]), value] }
                i += rest.isEmpty ? 2 : 1
            } else { i += 1 }
        }
        return []
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
