import Foundation
import os
import Core

/// Why a terminal couldn't be started: which step failed and with what errno, so "Input/output error" says where.
public struct PTYError: Error, LocalizedError, CustomStringConvertible {
    public var step: String, code: Int32
    public var description: String { "Couldn't start the terminal (\(step): \(String(cString: strerror(code))), errno \(code))" }
    public var errorDescription: String? { description }
}

/// A child process on a pseudo-terminal. The daemon owns this, so the process outlives any UI.
/// Once the program has exited its fd and pid are gone for good: they may already name another session's terminal or
/// another process, so nothing is written to the one or signalled at the other after that.
public final class PTY: @unchecked Sendable {   // closed under io, reaped under life; source and the rest on q
    public let pid: pid_t
    let primaryFD: Int32
    private var source: DispatchSourceRead?
    private let q = DispatchQueue(label: "kelp.pty")
    private var exited = false
    private let io = NSLock()     // `closed`: the primaryFD is closed under it, so no write lands in a reused fd
    private let life = NSLock()   // `reaped`: set before the pid is reaped, so no signal reaches a recycled one
    private var closed = false, reaped = false, started = false
    /// Typing goes out on a queue of its own, from a copy of the terminal's fd that only this queue closes: a program that
    /// isn't reading can't hold up the caller (a connection's reader thread) or anything that needs `io`, and a write never
    /// reaches a reused fd number. `stopWrites` (under io) ends a write that's waiting for room.
    let writes = DispatchQueue(label: "kelp.pty.write")
    let writeFD: Int32
    private var stopWrites = false
    /// Closes the terminal's fd from the read source's cancel handler, once GCD is done with it: closing right after
    /// `cancel()` could pull the fd from under a read still running (which would then read whatever reuses the number).
    private let closer: FDCloser

    public var onOutput: (@Sendable (Data) -> Void)?
    public var onExit: (@Sendable (Int32) -> Void)?

    /// `trampoline`: the `kelp` binary that makes the PTY the child's controlling terminal (nil spawns directly).
    public init(argv: [String], cwd: String, env: [String: String], cols: UInt16 = 120, rows: UInt16 = 32, trampoline: String? = PTY.trampoline) throws {
        let started = try Self.retrying { try Self.launch(argv: argv, cwd: cwd, env: env, cols: cols, rows: rows, trampoline: trampoline) }
        self.pid = started.pid; self.primaryFD = started.fd
        self.writeFD = dup(started.fd)
        self.closer = FDCloser(started.fd)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)   // shared with primaryFD: its reads already allow EAGAIN
    }

    /// A program the kelpd this one replaced started (`Handover`): still this process's child, its terminal's fd kept
    /// open across exec.
    init(adopting pid: pid_t, fd: Int32) {
        self.pid = pid; primaryFD = fd
        writeFD = dup(fd)
        closer = FDCloser(fd)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
    }

    /// For the kelpd that takes over (`Handover`): output stops being read here once what was read is handled, and the fd
    /// stays open, never written or closed here again. The program's exit is that one's to read. Nil once it has ended.
    func handOver() -> Int32? {
        q.sync {
            let fd = io.withLock { () -> Int32? in
                guard !closed, !exited, let s = source else { return nil }
                closed = true; stopWrites = true
                s.cancel(); source = nil   // `closer` isn't asked: the fd stays open
                return primaryFD
            }
            if fd != nil { exited = true; let w = writeFD; writes.async { close(w) } }
            return fd
        }
    }

    /// A terminal that was freed a moment ago can refuse to open its slave side (EIO, or ENXIO from openpty itself, seen
    /// with several daemons starting terminals at once) while the kernel is still tearing it down; a fresh terminal a few
    /// milliseconds later works. Any other failure is returned at once.
    static func retrying<T>(attempts: Int = 4, _ body: () throws -> T) throws -> T {
        for attempt in 1..<attempts {
            do { return try body() }
            catch let e as PTYError where e.code == EIO || e.code == ENXIO { usleep(UInt32(attempt) * 20_000) }   // ENXIO: openpty raced the same
        }
        return try body()
    }

    // swiftlint:disable:next function_parameter_count
    private static func launch(argv: [String], cwd: String, env: [String: String], cols: UInt16, rows: UInt16, trampoline: String?) throws -> (pid: pid_t, fd: Int32) {
        var m: Int32 = 0, s: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &ws) == 0 else { throw PTYError(step: "openpty", code: errno) }
        var nameBuf = [CChar](repeating: 0, count: 128)
        ptsname_r(m, &nameBuf, nameBuf.count)
        let secondaryPath = String(cString: nameBuf)
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
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let e = environment(ProcessInfo.processInfo.environment, env)
        let cargv = (argv.map { strdup($0) } + [nil]) as [UnsafeMutablePointer<CChar>?]
        let cenv = (e.map { strdup("\($0)=\($1)") } + [nil]) as [UnsafeMutablePointer<CChar>?]
        defer { cargv.forEach { free($0) }; cenv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc: Int32
        if let tramp = trampoline {
            // kelp __ctty: claims the tty as controlling terminal, then execs the agent (PATH from the child env).
            let targv = ([strdup(tramp), strdup("__ctty")] + cargv.dropLast() + [nil]) as [UnsafeMutablePointer<CChar>?]
            rc = posix_spawn(&pid, tramp, &fa, &attr, targv, cenv)
            free(targv[0]); free(targv[1])
        } else {
            rc = posix_spawnp(&pid, argv[0], &fa, &attr, cargv, cenv)
        }
        close(s)
        guard rc == 0 else { close(m); throw PTYError(step: "spawn \(trampoline == nil ? argv[0] : "via trampoline") on \(secondaryPath)", code: rc) }
        return (pid, m)
    }

    /// Starts reading the output and waiting for the exit. Set `onOutput` / `onExit` first: a program that prints (or
    /// fails) at once would otherwise lose that.
    public func start() {
        let first = io.withLock { () -> Bool in
            guard !started, !closed else { return false }
            started = true; return true
        }
        guard first else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: primaryFD, queue: q)
        src.setEventHandler { [weak self] in self?.drain() }
        let closer = closer
        src.setCancelHandler { closer.cancelled() }
        q.sync { source = src }
        src.resume()
        let pid = pid
        DispatchQueue(label: "kelp.pty.wait").async { [weak self] in
            // Wait without reaping: while it's a zombie its pid can't be anyone else's, so `reaped` goes up first.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
            self?.life.withLock { self?.reaped = true }
            var st: Int32 = 0
            while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
            guard let pty = self else { return }
            let status = st
            pty.q.async { pty.finish(status) }
        }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(primaryFD, &buf, buf.count)
        if n > 0 { onOutput?(Data(buf[0..<n])) }
        else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { source?.cancel(); source = nil }
    }

    private func finish(_ status: Int32) {
        guard !exited else { return }
        exited = true
        // Flush anything still buffered in the kernel.
        var buf = [UInt8](repeating: 0, count: 65536)
        if !io.withLock({ closed }) {   // already hung up (dropped): the fd isn't ours any more
            let fl = fcntl(primaryFD, F_GETFL); _ = fcntl(primaryFD, F_SETFL, fl | O_NONBLOCK)
            while true { let n = read(primaryFD, &buf, buf.count); if n <= 0 { break }; onOutput?(Data(buf[0..<n])) }
        }
        hangUp()
        onExit?(status)
    }

    private func hangUp() {
        let first = io.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true; stopWrites = true
            if let s = source { closer.ask(); s.cancel(); source = nil } else { close(primaryFD) }   // with a source: closed in its cancel handler
            return true
        }
        // Once only (finish and deinit both get here): a second close would hit whatever reused the number since.
        guard first else { return }
        let w = writeFD
        writes.async { close(w) }   // after any write still queued has given up
    }

    /// Dropped while its program runs (the limits probe quits that way): hang up the terminal. A controlling process
    /// waits in exit until its output is read, and nobody reads it any more.
    deinit { hangUp() }

    /// The `kelp` CLI next to the daemon binary.
    public static let trampoline: String? = {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var p = dir.appendingPathComponent("kelp").path
        #if DEBUG
        // Tests run inside xctest: the kelp built with them (else a test that dies leaves programs without a terminal running).
        if let t = ProcessInfo.processInfo.environment["KELP_TRAMPOLINE"] { p = t }
        #endif
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }()

    static let scrubbed = ["CLAUDECODE", "CLAUDE_CODE_", "CODEX_SANDBOX", "CODEX_THREAD", "KELP_SESSION", "TERM_PROGRAM", "ITERM_", "VSCODE_"]

    /// A session's environment: the daemon's, without what doesn't belong to a new session, under the session's own.
    static func environment(_ daemon: [String: String], _ env: [String: String]) -> [String: String] {
        // Don't leak the environment of whatever started the daemon (e.g. an agent's session markers) into new sessions.
        var e = daemon.filter { k, _ in !scrubbed.contains { k.hasPrefix($0) } }.merging(env) { $1 }
        e["TERM"] = "xterm-256color"; e["COLORTERM"] = "truecolor"
        // A daemon started by launchd has no locale, and without one pbcopy reads UTF-8 as Mac Roman: Grok's copies of
        // Russian text came out as "–ü—è—Ç…". A locale the user set stays.
        if !e.keys.contains(where: { ["LANG", "LC_ALL", "LC_CTYPE"].contains($0) }) { e["LANG"] = "en_US.UTF-8" }
        return e
    }

    /// Typing into the program; dropped once it has exited (the fd may be another terminal's by then).
    public func write(_ d: Data) {
        guard !io.withLock({ closed }) else { return }
        writes.async { [self] in
            var rest = d[...]
            while !rest.isEmpty, !io.withLock({ stopWrites }) {
                let n = rest.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
                if n > 0 { rest = rest.dropFirst(n); continue }
                guard n < 0, errno == EAGAIN || errno == EINTR else { return }   // EIO: the program's side is gone
                var fds = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
                _ = poll(&fds, 1, 100)   // wait for room, looking at stopWrites every 0.1 s
            }
        }
    }

    /// The program in the foreground when it isn't the one the PTY started (a shell running `npm run dev`, vim…).
    public var foregroundProgram: String? {
        let pg = io.withLock { closed ? -1 : tcgetpgrp(primaryFD) }
        guard pg > 0, pg != pid else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pg, &name, UInt32(name.count)) > 0 ? String(cString: name) : "a program"
    }

    public func resize(cols: UInt16, rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        io.withLock { if !closed { _ = ioctl(primaryFD, TIOCSWINSZ, &ws) } }
    }
    public func kill() { signal { Darwin.kill(-$0, SIGHUP); Darwin.kill($0, SIGTERM) } }

    /// The program and everything it started, read now: a shell runs each job in a process group of its own, and once
    /// the shell is gone its jobs belong to launchd and can't be found from here any more.
    public func tree() -> [pid_t] { life.withLock { reaped ? [] : Subprocess.tree(pid) } }

    /// Hangup and SIGTERM to the program and everything it started (a server in a shell's job too), then SIGKILL to
    /// whatever is still there after `grace` seconds (some TUIs ignore SIGTERM, servers treat SIGHUP as "reload").
    /// Returns them all, for `Sessions.waitGone`.
    @discardableResult
    public func terminate(grace: TimeInterval = 2) -> [pid_t] {
        let all = tree()
        kill()
        for p in all.dropFirst() { Darwin.kill(p, SIGHUP); Darwin.kill(p, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in   // keeps the PTY, and so `reaped`, until then
            signal { if Darwin.kill($0, 0) == 0 { Darwin.kill(-$0, SIGKILL); Darwin.kill($0, SIGKILL) } }
        }
        Subprocess.killLater(Array(all.dropFirst()), after: grace)
        return all
    }

    /// `f(pid)` while the pid is still this program's.
    private func signal(_ f: (pid_t) -> Void) { life.withLock { if !reaped { f(pid) } } }
}

/// Closes an fd from a dispatch source's cancel handler, only when asked to (a source cancelled at EOF leaves it open).
private final class FDCloser: Sendable {
    let fd: Int32
    private let state = OSAllocatedUnfairLock<(asked: Bool, done: Bool)>(initialState: (false, false))
    init(_ fd: Int32) { self.fd = fd }
    func ask() { state.withLock { $0.asked = true } }
    func cancelled() { state.withLock { if $0.asked && !$0.done { $0.done = true; close(fd) } } }
}
