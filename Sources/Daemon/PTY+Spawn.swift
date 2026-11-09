import Core
import Foundation

// Starting a program on a new pseudo-terminal: openpty and posix_spawn (through kelp __ctty), retried, in its own environment.

extension PTY {
    /// A terminal that was freed a moment ago can refuse to open its slave side (EIO, or ENXIO from openpty itself, seen
    /// with several daemons starting terminals at once) while the kernel is still tearing it down; a fresh terminal a few
    /// milliseconds later works. Any other failure is returned at once.
    static func retrying<T>(attempts: Int = 4, _ body: () throws -> T) throws -> T {
        for attempt in 1..<attempts {
            do { return try body() } catch let error as PTYError where error.code == EIO || error.code == ENXIO {
                usleep(UInt32(attempt) * 20_000)
            }   // ENXIO: openpty raced the same
        }
        return try body()
    }

    // swiftlint:disable:next function_parameter_count
    static func launch(
        argv: [String], cwd: String, env: [String: String], cols: UInt16, rows: UInt16,
        trampoline: String?
    ) throws -> (pid: pid_t, fd: Int32) {
        var primary: Int32 = 0, secondary: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &ws) == 0 else { throw PTYError(step: "openpty", code: errno) }
        var nameBuf = [CChar](repeating: 0, count: 128)
        ptsname_r(primary, &nameBuf, nameBuf.count)
        let secondaryPath = String(cBuffer: nameBuf)
        // Keep our end of the slave open until the child has it: closing the last fd resets the tty (size becomes 0×0).

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        posix_spawn_file_actions_addopen(&fa, 0, secondaryPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fa, 0, 1)
        posix_spawn_file_actions_adddup2(&fa, 0, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Reset signal state: the child must not inherit our ignored/blocked signals (SIGHUP/SIGTERM would be no-ops).
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(
            &attr,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let childEnv = environment(ProcessInfo.processInfo.environment, env)
        let cargv = (argv.map { strdup($0) } + [nil]) as [UnsafeMutablePointer<CChar>?]
        let cenv = (childEnv.map { strdup("\($0)=\($1)") } + [nil]) as [UnsafeMutablePointer<CChar>?]
        defer {
            cargv.forEach { free($0) }
            cenv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc: Int32
        if let tramp = trampoline {
            // kelp __ctty: claims the tty as controlling terminal, then execs the agent (PATH from the child env).
            let targv =
                ([strdup(tramp), strdup("__ctty")] + cargv.dropLast() + [nil]) as [UnsafeMutablePointer<CChar>?]
            rc = posix_spawn(&pid, tramp, &fa, &attr, targv, cenv)
            free(targv[0])
            free(targv[1])
        } else {
            rc = posix_spawnp(&pid, argv[0], &fa, &attr, cargv, cenv)
        }
        close(secondary)
        guard rc == 0 else {
            close(primary)
            throw PTYError(
                step: "spawn \(trampoline == nil ? argv[0] : "via trampoline") on \(secondaryPath)", code: rc)
        }
        return (pid, primary)
    }

    /// The `kelp` CLI next to the daemon binary.
    public static let trampoline: String? = {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var path = dir.appendingPathComponent("kelp").path
        #if DEBUG
            // Tests run inside xctest: the kelp built with them (else a test that dies leaves programs without a terminal running).
            if let override = ProcessInfo.processInfo.environment["KELP_TRAMPOLINE"] { path = override }
        #endif
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    static let scrubbed = [
        "CLAUDECODE", "CLAUDE_CODE_", "CODEX_SANDBOX", "CODEX_THREAD", "KELP_SESSION", "TERM_PROGRAM", "ITERM_",
        "VSCODE_"
    ]

    /// A session's environment: the daemon's, without what doesn't belong to a new session, under the session's own.
    static func environment(_ daemon: [String: String], _ env: [String: String]) -> [String: String] {
        // Don't leak the environment of whatever started the daemon (e.g. an agent's session markers) into new sessions.
        var merged = daemon.filter { k, _ in !scrubbed.contains { k.hasPrefix($0) } }.merging(env) { $1 }
        merged["TERM"] = "xterm-256color"
        merged["COLORTERM"] = "truecolor"
        // Ghostty shows OSC 8 links, but programs only print them for terminals they know (TERM_PROGRAM, scrubbed
        // above): without this, Claude Code's artifact chip is plain text. A user's FORCE_HYPERLINK=0 stays.
        if merged["FORCE_HYPERLINK"] == nil { merged["FORCE_HYPERLINK"] = "1" }
        // A daemon started by launchd has no locale, and without one pbcopy reads UTF-8 as Mac Roman: Grok's copies of
        // Russian text came out as "–ü—è—Ç…". A locale the user set stays.
        if !merged.keys.contains(where: { ["LANG", "LC_ALL", "LC_CTYPE"].contains($0) }) {
            merged["LANG"] = "en_US.UTF-8"
        }
        return merged
    }
}
