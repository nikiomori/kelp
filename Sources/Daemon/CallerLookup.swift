import Agents
import Core
import Foundation
import os

/// Who a call comes from (`Caller`), by the process on the connection: what `Daemon.allow` lets it do goes by this.
/// The user's when Kelp can tell it's theirs: Kelp's window and its terminals, a terminal of Kelp's no agent is on the line
/// of, or a program that came from a system service (an ancestor of another account that isn't a setuid program: `sshd`,
/// cron) or from an app that isn't a Kelp (Terminal, iTerm, an editor). Anything else is held to an agent's rules: a
/// program that left its terminal and every such ancestor behind (a double fork with `setsid`, `script` in the
/// background, `tmux new -d`, a launchd job), and whatever runs under a known agent's program, one the user typed in by
/// hand included (`Caller.typedAgent`). This fences an agent's slips and one steered into such a command; one set on
/// getting around it can (a cron line of its own, a bundle of its own, an app it starts): docs/architecture.md.
/// This is the daemon's one place that tells, apart from the sessions it reads from (their programs, their terminals).
final class Callers: Sendable {
    /// What a session started by `Caller.kelpd` records as its origin, and so its line (`lineage`): one that breaks off.
    static let ownProgram = "kelpd"
    /// The same for `Caller.unknown`, and for `Caller.detached`.
    static let unknown = "unknown", detached = "detached"
    private let live: SessionTable, clients: Clients, store: Store
    /// Whether a caller has to be known for the user's to count as theirs: kelpd says so as it starts (`Daemon.strict`).
    /// A test's in-process daemon doesn't, and its test process calls as the user.
    let strict = OSAllocatedUnfairLock(initialState: false)
    /// Who is attached to a tmux pane's session, by the pane's terminal, for 10 s (`tmuxPane`).
    private let tmuxAnswers = OSAllocatedUnfairLock<[String: (pane: TmuxPane?, at: Date)]>(initialState: [:])
    struct TmuxPane: Sendable { let attached: [Caller], shown: Bool }

    init(live: SessionTable, clients: Clients, store: Store) {
        self.live = live
        self.clients = clients
        self.store = store
    }

    /// The live session whose program `pid` is, or runs under (its own child, a shell's job…), or whose terminal it or
    /// one of its parents has (a double fork, `nohup`, `script`); `kelpd` for one this daemon started (kelpd leads its
    /// own process session: kelpd/main.swift); one in a tmux pane is whoever is attached there (`tmuxPane`).
    func session(running pid: pid_t, throughTmux: Bool = true) -> Caller {
        guard pid == getpid() || Subprocess.parent(pid) != nil else { return .unknown }
        guard pid != getpid() else { return .user }
        let all = live.all
        let mine = Dictionary(all.map { ($0.pty.pid, $0.snapshot.id) }) { a, _ in a }
        let agents = Set(all.filter { $0.snapshot.isAgent }.map(\.snapshot.id))
        let strict = self.strict.withLock { $0 }
        var current = pid, chain: [pid_t] = [], underAgent = false
        // Under an agent the user ran by hand (`claude` typed in a shell, a tmux pane, Terminal): that agent's, not theirs.
        // Not in a session Kelp started an agent in, which is that agent's already (its own programs, a wrapper's child).
        func of(_ id: String) -> Caller {
            underAgent && !agents.contains(id) ? .typedAgent(id) : .session(id)
        }
        for _ in 0..<64 {
            if let id = mine[current] { return of(id) }
            if Subprocess.isRunning(current) { return .kelpd }
            // Under kelpd but in none of its sessions: its own; what kelpd came from isn't looked at (a test's in-process
            // daemon is the test, whose programs are the user's, whatever ran the test).
            if current == getpid() { return strict ? .kelpd : underAgent ? .detached : .user }
            chain.append(current)
            if !underAgent, Self.runsAnAgent(current) { underAgent = true }
            guard let up = Subprocess.parent(current), up > 1, up != current else { break }
            current = up
        }
        let ttys = Set(chain.compactMap(Subprocess.terminal))
        if let terminalSession = all.first(where: { Subprocess.terminal($0.pty.pid).map(ttys.contains) == true }) {
            // Left its line (`&`, `nohup`: launchd its parent now) with the terminal still its own: who left it there, the
            // user or an agent typed in (gone by now, perhaps), can't be told, so it's held to an agent's rules.
            if !underAgent, chain.last.flatMap(Subprocess.parent) == 1 { underAgent = true }
            return of(terminalSession.snapshot.id)
        }
        let daemon = getsid(0)   // a test's in-process daemon leads no session: then none of this
        if daemon == getpid(), getsid(pid) == daemon { return .kelpd }
        if throughTmux, let server = chain.last,
            Unix.executable(server).map({ URL(fileURLWithPath: $0).lastPathComponent }) == "tmux"
        {
            let pane = tmuxPane(pid, server: server, pane: chain.dropLast().last ?? pid)
            switch pane.flatMap({
                Self.tmuxDecision($0.attached, shown: $0.shown, underAgent: underAgent, isAgent: heldAsAgent)
            }) {
            case .session(let id): return of(id)
            case .user: return underAgent ? .detached : .user
            case let caller?: return caller
            case nil: return .detached
            }
        }
        guard strict else { return underAgent ? .detached : .user }
        return !underAgent && chain.dropFirst().contains { Self.cameFromTheUser($0) } ? .user : .detached
    }

    /// The programs of the agents Kelp knows (its presets'), by the name they're run as.
    static let agentPrograms: Set<String> = {
        Set(
            AgentManifest.presets.filter { !["shell", "custom"].contains($0.id) }.map {
                URL(fileURLWithPath: $0.command).lastPathComponent
            })
    }()

    /// Whether `pid` is one of those: by the name it was run as (`claude`, whose file is named for its version), or the
    /// script an interpreter runs (`node …/codex`, `python3 …/aider`).
    static func runsAnAgent(_ pid: pid_t) -> Bool {
        let agents = agentPrograms
        func interpreter(_ name: String) -> Bool {
            ["node", "bun", "deno", "ruby"].contains(name) || name.hasPrefix("python")
        }
        guard let argv = Subprocess.arguments(pid),
            let first = argv.first.map({ URL(fileURLWithPath: $0).lastPathComponent })
        else { return false }
        guard interpreter(first) else { return agents.contains(first) }
        // Its script: the first word that isn't an option, a path to one anywhere (`node --require x …/codex`), or the
        // module after `-m` (`python -m aider`); not any word (`python3 bench.py --agent claude` is the user's).
        let words = Array(argv.dropFirst())
        func names(_ word: String) -> Bool {
            agents.contains(URL(fileURLWithPath: word).deletingPathExtension().lastPathComponent)
        }
        if let first = words.first(where: { !$0.hasPrefix("-") }), names(first) { return true }
        if let moduleFlag = words.firstIndex(of: "-m"), moduleFlag + 1 < words.count, names(words[moduleFlag + 1]) {
            return true
        }
        return words.contains { $0.contains("/") && !$0.hasPrefix("-") && names($0) }
    }

    /// An ancestor that only the user's own login or an app starts: Kelp's window (its terminals' `kelp attach`), one of
    /// another account that isn't a setuid program anyone may run (`sshd`, cron; not `login`, `su`, `sudo`), or an app's
    /// own program that isn't a Kelp's (this one's, or another install's: a bundle with a kelpd in it).
    static func cameFromTheUser(_ pid: pid_t) -> Bool {
        let path = Unix.executable(pid)
        if path == Clients.appExecutable { return true }
        // iTerm's own: the server that keeps its sessions (restored ones) lives outside its bundle.
        if let path, path.hasPrefix(NSHomeDirectory() + "/Library/Application Support/iTerm2/iTermServer") {
            return true
        }
        if let uid = Subprocess.owner(pid), uid != getuid(), let path, !Self.isSetuid(path) { return true }
        guard let path, let range = path.range(of: ".app/Contents/MacOS/") else { return false }
        let folder = String(path[..<range.upperBound])
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
        if let range = me.range(of: ".app/Contents/") { return String(me[..<range.lowerBound]) + ".app/" }
        return URL(fileURLWithPath: me).deletingLastPathComponent().path + "/"
    }()

    /// The clients attached to the tmux session whose pane `pid` runs in (as callers), and whether that pane is the one
    /// shown (the active pane of the active window); nil for no tmux to ask. Asked once a pane and 10 s (`tmuxAnswers`):
    /// a hook comes from the same pane many times a turn.
    private func tmuxPane(_ pid: pid_t, server: pid_t, pane: pid_t) -> TmuxPane? {
        guard let dev = Subprocess.terminal(pid),
            let tty = devname(dev_t(dev), S_IFCHR).map({ "/dev/" + String(cString: $0) })
        else { return nil }
        // Kept for the pane it was asked for: one whose first program (the tmux server's child) was there before the
        // answer; a terminal's name is given to the next pane once one closes.
        if let kept = tmuxAnswers.withLock({ $0[tty] }), kept.at.timeIntervalSinceNow > -10,
            let born = Subprocess.started(pane), Double(born) / 1e6 < kept.at.timeIntervalSince1970
        {
            return kept.pane
        }
        let socket = Self.tmuxSocket(Subprocess.arguments(server) ?? [])
        func lines(_ args: [String]) -> [[Substring]] {
            // The server that pane is on: its socket as it was started with (-L, -S), else the default one (TMUX_TMPDIR).
            var env = ["PATH": Sessions.childPath]
            env["TMUX_TMPDIR"] = ProcessInfo.processInfo.environment["TMUX_TMPDIR"]
            do {
                let result = try Subprocess.run(
                    [try LoginPath.resolve("tmux")] + socket + args, cwd: NSHomeDirectory(), env: env, timeLimit: 2)
                guard result.status == 0 else { return [] }
                // The session's name last, whole: it may hold spaces.
                return String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map {
                    $0.split(separator: " ", maxSplits: 3)
                }
            } catch {
                Log.session.info("asking tmux who a caller is: \(error)")
                return []
            }
        }
        let format = "#{pane_tty} #{pane_active} #{window_active} #{session_name}"
        guard let row = lines(["list-panes", "-a", "-F", format]).first(where: { $0.first.map(String.init) == tty }),
            row.count == 4
        else {
            return nil
        }
        let clients = lines(["list-clients", "-t", "=" + row[3], "-F", "#{client_pid}"]).compactMap {
            $0.first.flatMap { pid_t($0) }
        }
        let found = TmuxPane(
            attached: clients.map { session(running: $0, throughTmux: false) }, shown: row[1] == "1" && row[2] == "1")
        tmuxAnswers.withLock { $0[tty] = (found, Date()) }
        return found
    }

    /// A session held to an agent's rules, as `Daemon.allow` holds it (`forAnAgent`); one that can't be read, too.
    func heldAsAgent(_ id: String) -> Bool {
        do { return try store.forAnAgent(id) } catch {
            Log.session.error("reading who started \(id): \(error)")
            return true
        }
    }

    /// A pane's caller from who's attached: an agent's session (or a typed agent) outweighs any other client, any pane; a
    /// caller under an agent typed in is that agent's in the user's terminal attached, shown or not; else a terminal of the
    /// user's, Kelp's or another app's, counts for the pane shown there only (not a window an agent added out of sight).
    static func tmuxDecision(
        _ attached: [Caller], shown: Bool, underAgent: Bool = false, isAgent: (String) -> Bool = { _ in false }
    ) -> Caller? {
        if let typed = attached.first(where: { if case .typedAgent = $0 { true } else { false } }) { return typed }
        let sessions = attached.compactMap { if case .session(let id) = $0 { id } else { nil } }
        if let agent = sessions.first(where: isAgent) { return .session(agent) }
        if underAgent, let terminal = sessions.first { return .session(terminal) }
        guard shown else { return nil }
        return sessions.first.map(Caller.session) ?? (attached.contains(.user) ? .user : nil)
    }

    /// The `-L name` or `-S path` a tmux server was started with, for asking that server: among tmux's own options, before
    /// its command (`tmux new ssh -L 8080:h:80 host` names no socket), apart (`-L work`) or joined (`-Lwork`).
    static func tmuxSocket(_ argv: [String]) -> [String] {
        let valued: Set<Character> = ["c", "f", "L", "S", "T"]   // tmux's options that take a value
        var index = 1
        while index < argv.count, argv[index].hasPrefix("-"), argv[index] != "-" {
            let flags = Array(argv[index].dropFirst())
            if let at = flags.firstIndex(where: valued.contains) {
                let rest = String(flags[(at + 1)...]),
                    value = rest.isEmpty ? (index + 1 < argv.count ? argv[index + 1] : "") : rest
                if flags[at] == "L" || flags[at] == "S" { return ["-" + String(flags[at]), value] }
                index += rest.isEmpty ? 2 : 1
            } else {
                index += 1
            }
        }
        return []
    }

    /// Who the program on `conn` is: its process tree, looked up once per connection (`Connection.owner`), as it connects
    /// (Daemon.serve), while it's surely there. The daemon's own calls (`conn` -1) are the user's, and Kelp's window,
    /// which launchd starts with no terminal; a connection gone already is `kelpd`'s, one whose program can't be read `unknown`.
    func caller(_ conn: Int) -> Caller {
        guard let connection = clients.connection(conn) else { return conn < 0 ? .user : .kelpd }
        if let known = connection.owner.withLock({ $0 }) { return known }
        let seen = connection.peerPID.map { session(running: $0) } ?? .unknown   // not under the connection's lock: this takes the sessions'
        let found: Caller = seen == .detached && connection.peer == Clients.appExecutable ? .user : seen
        connection.owner.withLock { $0 = found }
        return found
    }
}
