import Core
import Foundation
import os

/// Why a terminal couldn't be started: which step failed and with what errno, so "Input/output error" says where.
public struct PTYError: Error, LocalizedError, CustomStringConvertible {
    public var step: String, code: Int32
    public var description: String {
        "Couldn't start the terminal (\(step): \(String(cString: strerror(code))), errno \(code))"
    }
    public var errorDescription: String? { description }
}

/// A child process on a pseudo-terminal. The daemon owns this, so the process outlives any UI.
/// Once the program has exited its fd and pid are gone for good: they may already name another session's terminal or
/// another process, so nothing is written to the one or signalled at the other after that.
public final class PTY: @unchecked Sendable {   // phases under `phase`; source (set on `queue`) under it too
    public let pid: pid_t
    let primaryFD: Int32
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "kelp.pty")

    /// The terminal's fd: read here from `start`, until it's handed to the next kelpd or hung up. Once it's neither
    /// waiting nor read, nothing touches it again: the number may be another terminal's.
    enum Terminal { case waiting, reading, handedOver, hungUp }
    /// The program: its pid is ours to signal until it's reaped (here), or handed over (reaped by the next kelpd).
    enum Program { case running, handedOver, reaped }
    struct Phase {
        var terminal = Terminal.waiting, program = Program.running
        var open: Bool { terminal == .waiting || terminal == .reading }
    }
    /// Every change of phase, and what must happen with one (closing the fd, a signal to the pid), is under this lock.
    private let phase = OSAllocatedUnfairLock(initialState: Phase())
    var phases: Phase { phase.withLock { $0 } }
    /// Its output is still read here: false once the terminal is closed, or its program let go of it (EOF) and runs on.
    var reading: Bool { phase.withLock { _ in source != nil } }

    /// Typing goes out on a queue of its own, from a copy of the terminal's fd that only this queue closes: a program that
    /// isn't reading can't hold up the caller (a connection's reader thread) or anything that needs `phase`, and a write
    /// never reaches a reused fd number. A write waiting for room stops once the terminal isn't open.
    let writes = DispatchQueue(label: "kelp.pty.write")
    let writeFD: Int32
    /// Bytes given to `write` and not yet written (or given up on), at most `queueLimit` (64 MiB).
    let queued = OSAllocatedUnfairLock(initialState: 0)
    static let queueLimit = 64 << 20
    /// Closes the terminal's fd from the read source's cancel handler, once GCD is done with it: closing right after
    /// `cancel()` could pull the fd from under a read still running (which would then read whatever reuses the number).
    private let closer: FDCloser

    public var onOutput: (@Sendable (Data) -> Void)?
    public var onExit: (@Sendable (Int32) -> Void)?

    /// `trampoline`: the `kelp` binary that makes the PTY the child's controlling terminal (nil spawns directly).
    public init(
        argv: [String], cwd: String, env: [String: String], cols: UInt16 = 120, rows: UInt16 = 32,
        trampoline: String? = PTY.trampoline
    ) throws {
        let started = try Self.retrying {
            try Self.launch(argv: argv, cwd: cwd, env: env, cols: cols, rows: rows, trampoline: trampoline)
        }
        self.pid = started.pid
        self.primaryFD = started.fd
        self.writeFD = dup(started.fd)
        self.closer = FDCloser(started.fd)
        guard writeFD >= 0 else { throw RPCError.internalError("No file descriptors left for a new terminal.") }
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)   // shared with primaryFD: its reads already allow EAGAIN
    }

    /// A program the kelpd this one replaced started (`Handover`): still this process's child, its terminal's fd kept
    /// open across exec.
    init(adopting pid: pid_t, fd: Int32) {
        self.pid = pid
        primaryFD = fd
        writeFD = dup(fd)
        closer = FDCloser(fd)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
    }

    /// For the kelpd that takes over (`Handover`): output stops being read here once what was read is handled, and the fd
    /// stays open, never written or closed here again. The program's exit is that one's to read. Nil once it has ended
    /// (being reaped here: the new kelpd would find no such child). One not started yet goes too, and one whose output
    /// already ended while its program runs on.
    func handOver() -> Int32? {
        queue.sync {
            let given = phase.withLock { current -> Bool in
                guard current.open, current.program == .running else { return false }
                current.terminal = .handedOver
                current.program = .handedOver
                source?.cancel()
                source = nil   // `closer` isn't asked: the fd stays open
                return true
            }
            guard given else { return nil }
            let fd = writeFD
            writes.async { close(fd) }
            return primaryFD
        }
    }

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
    private static func launch(
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

    /// Starts reading the output and waiting for the exit. Set `onOutput` / `onExit` first: a program that prints (or
    /// fails) at once would otherwise lose that.
    public func start() {
        let first = phase.withLock { current -> Bool in
            guard current.terminal == .waiting else { return false }
            current.terminal = .reading
            return true
        }
        guard first else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: primaryFD, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        let closer = closer
        src.setCancelHandler { closer.cancelled() }
        closer.watch()
        queue.sync { phase.withLock { _ in source = src } }
        src.resume()
        watchExit()
    }

    /// The program's exit, seen without a thread of its own waiting for it (a process source). A zombie until `reaped`
    /// goes up, so its pid can't be anyone else's meanwhile; one handed over is the next kelpd's to reap. The source
    /// keeps itself until it fired, so a PTY dropped meanwhile still has its program reaped.
    private func watchExit() {
        // The phase itself, not through the PTY: one dropped after a hand-over (an update's exec that failed, its sessions
        // taken back by a new PTY on the same pid) must still see it was handed over, and leave the reaping to that one.
        let pid = pid, once = OSAllocatedUnfairLock(initialState: false), phase = phase
        let exits = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        let reap: @Sendable () -> Void = { [weak self] in
            guard
                once.withLock({ first in
                    defer { first = true }
                    return !first
                })
            else { return }
            exits.cancel()
            let handedOver = phase.withLock { current -> Bool in
                if current.program == .handedOver { return true }
                current.program = .reaped
                return false
            }
            if handedOver { return }
            var st: Int32 = 0
            while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
            guard let pty = self else { return }
            let status = st
            pty.queue.async { pty.finish(status) }
        }
        exits.setEventHandler(handler: reap)
        exits.resume()
        // Exited before the source was armed (a process source misses one that's already a zombie): seen here.
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) == 0, info.si_pid == pid { reap() }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let count = read(primaryFD, &buf, buf.count)
        if count > 0 {
            onOutput?(Data(buf[0..<count]))
        } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
            phase.withLock { _ in
                source?.cancel()
                source = nil
            }
        }
    }

    /// Once: the wait thread is the only caller, and only for a program reaped here.
    private func finish(_ status: Int32) {
        // Flush anything still buffered in the kernel.
        var buf = [UInt8](repeating: 0, count: 65536)
        if phase.withLock({ $0.open }) {   // already hung up (dropped): the fd isn't ours any more
            let fl = fcntl(primaryFD, F_GETFL)
            _ = fcntl(primaryFD, F_SETFL, fl | O_NONBLOCK)
            while true {
                let count = read(primaryFD, &buf, buf.count)
                if count <= 0 { break }
                onOutput?(Data(buf[0..<count]))
            }
        }
        hangUp()
        onExit?(status)
    }

    private func hangUp() {
        let first = phase.withLock { current -> Bool in
            guard current.open else { return false }
            current.terminal = .hungUp
            if let reader = source {
                reader.cancel()
                source = nil
            }
            closer.ask()   // closed once no source has it: now, or in the cancel handler (also of one ended by EOF)
            return true
        }
        // Once only (finish and deinit both get here): a second close would hit whatever reused the number since.
        guard first else { return }
        let fd = writeFD
        writes.async { close(fd) }   // after any write still queued has given up
    }

    /// Dropped while its program runs (the limits probe quits that way): hang up the terminal. A controlling process
    /// waits in exit until its output is read, and nobody reads it any more.
    deinit { hangUp() }

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

    /// Typing into the program; dropped once it has exited (the fd may be another terminal's by then).
    public func write(_ data: Data) {
        guard phase.withLock({ $0.open }) else { return }
        // A program that stops reading doesn't make the daemon keep whatever is pasted at it: past the limit, it's dropped.
        let room = queued.withLock { count -> Bool in
            guard count + data.count <= Self.queueLimit else { return false }
            count += data.count
            return true
        }
        guard room else {
            Log.session.error("dropped \(data.count) bytes of input: \(self.pid) isn't reading what it was sent")
            return
        }
        writes.async { [self] in
            defer { queued.withLock { $0 -= data.count } }
            var rest = data[...]
            while !rest.isEmpty, phase.withLock({ $0.open }) {
                let sent = rest.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
                if sent > 0 {
                    rest = rest.dropFirst(sent)
                    continue
                }
                guard sent < 0, errno == EAGAIN || errno == EINTR else { return }   // EIO: the program's side is gone
                var fds = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
                _ = poll(&fds, 1, 100)   // wait for room, looking at the phase every 0.1 s
            }
        }
    }

    /// The program in the foreground when it isn't the one the PTY started (a shell running `npm run dev`, vim…).
    public var foregroundProgram: String? {
        guard let pg = foregroundGroup else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pg, &name, UInt32(name.count)) > 0 ? String(cBuffer: name) : "a program"
    }

    /// The foreground's process group (its leader's pid) when it isn't the program the PTY started.
    public var foregroundGroup: pid_t? {
        let pg = phase.withLock { $0.open ? tcgetpgrp(primaryFD) : -1 }
        return pg > 0 && pg != pid ? pg : nil
    }

    public func resize(cols: UInt16, rows: UInt16) {
        let ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        phase.withLock {
            if $0.open {
                var ws = ws
                _ = ioctl(primaryFD, TIOCSWINSZ, &ws)
            }
        }
    }
    public func kill() {
        signal {
            Darwin.kill(-$0, SIGHUP)
            Darwin.kill($0, SIGTERM)
        }
    }

    /// The program and everything it started, read now: a shell runs each job in a process group of its own, and once
    /// the shell is gone its jobs belong to launchd and can't be found from here any more.
    public func tree() -> [pid_t] { phase.withLock { $0.program == .reaped ? [] : Subprocess.tree(pid) } }

    /// Hangup and SIGTERM to the program and everything it started (a server in a shell's job too), then SIGKILL to
    /// whatever is still there after `grace` seconds (some TUIs ignore SIGTERM, servers treat SIGHUP as "reload").
    /// Returns them all, for `Sessions.waitGone`.
    @discardableResult
    public func terminate(grace: TimeInterval = 2) -> [pid_t] {
        let all = tree()
        kill()
        for child in all.dropFirst() {
            Darwin.kill(child, SIGHUP)
            Darwin.kill(child, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            signal {
                if Darwin.kill($0, 0) == 0 {
                    Darwin.kill(-$0, SIGKILL)
                    Darwin.kill($0, SIGKILL)
                }
            }   // keeps `phase` until then
        }
        Subprocess.killLater(Array(all.dropFirst()), after: grace)
        return all
    }

    /// `action(pid)` while the pid is still this program's.
    private func signal(_ action: @Sendable (pid_t) -> Void) {
        phase.withLock { if $0.program != .reaped { action(pid) } }
    }
}

/// Closes an fd when asked, but never while a dispatch source still has it. Not asked (a hand-over), it stays open.
final class FDCloser: Sendable {
    let fd: Int32
    private let state = OSAllocatedUnfairLock<(asked: Bool, watched: Bool, done: Bool)>(
        initialState: (false, false, false))
    private let closeFD: @Sendable (Int32) -> Void
    init(_ fd: Int32, closing: @escaping @Sendable (Int32) -> Void = { _ = close($0) }) {
        self.fd = fd
        closeFD = closing
    }
    /// A read source has the fd from now until its cancel handler runs (`cancelled`).
    func watch() { state.withLock { $0.watched = true } }
    /// Close it once no source has it: at once, or when the cancel handler runs. However the source ended (hung up, or
    /// its own EOF), the fd is closed once, never under GCD.
    func ask() {
        state.withLock {
            $0.asked = true
            closeIfDue(&$0)
        }
    }
    func cancelled() {
        state.withLock {
            $0.watched = false
            closeIfDue(&$0)
        }
    }
    private func closeIfDue(_ flags: inout (asked: Bool, watched: Bool, done: Bool)) {
        if flags.asked && !flags.watched && !flags.done {
            flags.done = true
            closeFD(fd)
        }
    }
}
