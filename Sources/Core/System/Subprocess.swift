import Foundation
import os

/// `Subprocess` runs a program to its end and collects what it printed, whether git, gh, ssh, `ps` or an extension's
/// command. All of them go through it, so each gets the same care:
/// - The pipes are read on their own threads as data arrives. A blocked read never takes a thread of the cooperative
///   pool, and a full pipe never stops the program.
/// - stdin is written alongside. When a program exits without reading it, that write fails instead of raising SIGPIPE.
/// - After `timeLimit`, the program is stopped along with everything it started (`stopTree`), because its children hold
///   the pipes too.
/// - A child that outlives the program and holds the pipes (a daemon it started) doesn't hold up the result.
/// `ProgramError` is a program that `Subprocess.checked` ran and that didn't succeed. It holds the exit status (the
/// signal's, when the time limit stopped it) and what the program said on stderr, or why its output wasn't read.
public struct ProgramError: Error, CustomStringConvertible, Sendable {
    public var program: String
    public var status: Int32
    public var stderr: String
    public var description: String { "\(program) failed (\(status)): \(stderr)" }
    /// The error as people read it: the first sentence of stderr without "fatal:". A line ending in "…overwritten by
    /// checkout:" keeps the line after it.
    public var message: String { Self.firstSentence(stderr) ?? description }

    public init(program: String, status: Int32, stderr: String) {
        self.program = program
        self.status = status
        self.stderr = stderr
    }

    /// Returns what a program said on stderr as one sentence for people, or nil when it said nothing.
    public static func firstSentence(_ stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty
        }
        guard var first = lines.first else { return nil }
        for prefix in ["fatal: ", "error: "] where first.hasPrefix(prefix) { first.removeFirst(prefix.count) }
        if first.hasSuffix(":"), lines.count > 1 { first += " " + lines[1] }
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}

public enum Subprocess {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        /// True when the time limit stopped the program. Its status is then the signal's.
        public var timedOut: Bool
        /// True when the program printed more than the run's `limit` on stdout or stderr. That stream then holds only
        /// its first `limit` bytes.
        public var truncated: Bool
    }

    /// How much of each stream `run` keeps unless told otherwise. It is far more than any answer git, gh or ssh give
    /// Kelp, but it stops a runaway (a diff of a regenerated dataset, a `cat` of a log) from taking the daemon's
    /// memory.
    public static let outputLimit = 64 << 20

    /// Runs `body` where no program may run: the daemon's connection reader while it applies an in-order call
    /// (`Handled.inOrder`) or a quick call (`Handled.quick`), which doesn't wait its turn behind slow programs. `run`
    /// refuses inside `body`, so the call fails instead of stalling.
    public static func quickOnly<T>(_ body: () throws -> T) rethrows -> T {
        let threadState = Thread.current.threadDictionary
        threadState[quickOnlyKey] = true
        defer { threadState[quickOnlyKey] = nil }
        return try body()
    }
    private static let quickOnlyKey = "dev.kelp.subprocess.quickOnly"

    /// Lets `body` start programs even though it runs in a quick or in-order call. It is only for a caller that has to
    /// answer after a program and holds up nobody else meanwhile, such as daemon.upgrade's check of the new kelpd,
    /// which the app waits for.
    public static func allowingPrograms<T>(_ body: () throws -> T) rethrows -> T {
        let threadState = Thread.current.threadDictionary, was = threadState[quickOnlyKey]
        threadState[quickOnlyKey] = nil
        defer { threadState[quickOnlyKey] = was }
        return try body()
    }

    /// `argv[0]` is a path, and `env` is the whole environment. After `limit` bytes a stream is still read to its end,
    /// so the program ends as it would have (its exit status, whatever it does besides printing). The rest is dropped
    /// and the output is marked `truncated`. A caller that needs all of it then fails, and one that can show a part
    /// says so. `started` gets the pid once the program runs, for a caller that may stop it with `stopTree`.
    public static func run(
        _ argv: [String], cwd: String, env: [String: String], stdin: Data? = nil, timeLimit: TimeInterval,
        limit: Int = outputLimit, started: ((pid_t) -> Void)? = nil
    ) throws -> Output {
        if Thread.current.threadDictionary[quickOnlyKey] != nil {
            let name = argv.first.map { ($0 as NSString).lastPathComponent } ?? "A program"
            throw RPCError.internalError("\(name) can't run from a quick or in-order call: it would hold up others.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv.first ?? "/usr/bin/false")
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = env
        let out = Reader(limit), err = Reader(limit), inp = stdin.map { _ in Pipe() }
        process.standardOutput = out.pipe
        process.standardError = err.pipe
        process.standardInput = inp ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        // Set before the program starts, so a program that exits at once isn't missed.
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let pid = process.processIdentifier
        running.withLock { _ = $0.insert(pid) }
        defer { running.withLock { _ = $0.remove(pid) } }
        started?(pid)
        out.start()
        err.start()
        if let inp, let stdin {
            let writer = inp.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            Thread.detachNewThread {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }
        var timedOut = false, ended = true
        if exited.wait(timeout: .now() + timeLimit) == .timedOut {
            timedOut = true
            stopTree(process.processIdentifier)
            // SIGKILL comes 2 s after SIGTERM. A process stuck in the kernel (a hung network mount) may outlast even
            // that.
            ended = exited.wait(timeout: .now() + 5) == .success
        }
        // Whatever is still in the pipes arrives at once, so only a child holding them open makes this wait run out.
        // The readers are then let go, or a reader thread and a pipe would stay as long as that child (an ssh master,
        // a daemon).
        for reader in [out, err] where reader.done.wait(timeout: .now() + 2) == .timedOut { reader.abandon() }
        // The status is read only once the program has exited. Asking a Process that still runs raises an exception,
        // which would take the daemon down.
        return Output(
            status: ended ? process.terminationStatus : -1, stdout: out.data, stderr: err.data, timedOut: timedOut,
            truncated: out.truncated || err.truncated)
    }

    /// The same as `run`, without holding the caller's thread. It is for async callers on the app's main actor or the
    /// cooperative pool.
    public static func run(
        _ argv: [String], cwd: String, env: [String: String], stdin: Data? = nil, timeLimit: TimeInterval,
        limit: Int = outputLimit
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(
                    with: Result { try run(argv, cwd: cwd, env: env, stdin: stdin, timeLimit: timeLimit, limit: limit) }
                )
            }
        }
    }

    /// Runs a program that has to succeed, meaning it exits with a code in `ok` before `timeLimit`: ssh, gh, `du`, a
    /// script. It runs in this process's environment with `env` laid over it, plus `LC_ALL=C`, so its output reads the
    /// same in every locale. A failure throws a `ProgramError` with what the program said. The first `limit` bytes of
    /// each stream are kept.
    public static func checked(
        _ argv: [String], cwd: String, env extra: [String: String] = [:], stdin: Data? = nil, ok: Set<Int32> = [0],
        timeLimit: TimeInterval = 300, limit: Int = outputLimit, started: ((pid_t) -> Void)? = nil
    ) throws -> Output {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env.merge(extra) { $1 }
        let result = try run(
            argv, cwd: cwd, env: env, stdin: stdin, timeLimit: timeLimit, limit: limit, started: started)
        guard ok.contains(result.status), !result.timedOut else {
            throw ProgramError(
                program: argv.first.map { ($0 as NSString).lastPathComponent } ?? "", status: result.status,
                stderr: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Returns all the output of `checked`. Output longer than `outputLimit` is an error, so a part is never taken for
    /// the whole.
    @discardableResult
    public static func output(
        _ argv: [String], cwd: String, env: [String: String] = [:], stdin: Data? = nil, ok: Set<Int32> = [0],
        timeLimit: TimeInterval = 300
    ) throws -> Data {
        let result = try checked(argv, cwd: cwd, env: env, stdin: stdin, ok: ok, timeLimit: timeLimit)
        guard !result.truncated else {
            throw ProgramError(
                program: argv.first.map { ($0 as NSString).lastPathComponent } ?? "", status: result.status,
                stderr: "It printed more than \(outputLimit >> 20) MB, more than Kelp reads.")
        }
        return result.stdout
    }

    /// Whether `pid` is a program that `run` started in this process and still waits for. What that program starts in
    /// turn (a repo's git hook, an extension's command) is then this process's doing, not a terminal's
    /// (`Callers.caller`).
    public static func isRunning(_ pid: pid_t) -> Bool { running.withLock { $0.contains(pid) } }
    private static let running = OSAllocatedUnfairLock<Set<pid_t>>(initialState: [])

    /// Sends SIGTERM to `pid` and everything it started, children first. The children are found before the parent goes,
    /// while they are still its children. After 2 s it sends SIGKILL to whatever is left, because a process that
    /// ignores SIGTERM would hold the pipes forever.
    public static func stopTree(_ pid: pid_t) {
        let all = tree(pid)
        for child in all.reversed() { kill(child, SIGTERM) }
        killLater(all, after: 2)
    }

    /// Like `stopTree`, but it waits. It sends SIGTERM, waits up to `grace` for the processes to go, then sends SIGKILL
    /// to whatever is left, all before it returns. It is for a process about to exec or exit, which could never send a
    /// later SIGKILL (`killLater`).
    public static func stopTreeNow(_ pid: pid_t, grace: TimeInterval = 2) {
        let born = tree(pid).map { ($0, started($0)) }
        for (child, _) in born.reversed() { kill(child, SIGTERM) }
        // A process on its way out no longer reports its start time, but it still answers kill(0) until it is a
        // zombie, so it isn't gone yet.
        func left() -> [pid_t] {
            born.compactMap { child, start in
                guard start != nil, !isZombie(child) else { return nil }
                let now = started(child)
                return now == start || (now == nil && kill(child, 0) == 0) ? child : nil
            }
        }
        let end = Date().addingTimeInterval(grace)
        while !left().isEmpty, Date() < end { usleep(50_000) }
        for child in left() { kill(child, SIGKILL) }
        let killed = Date().addingTimeInterval(1)   // SIGKILL takes effect a moment later.
        while !left().isEmpty, Date() < killed { usleep(10_000) }
    }

    /// Sends SIGKILL after `delay` to the processes in `pids` that still run. They are matched by start time, so a new
    /// process that has since been given one of those pids is left alone.
    public static func killLater(_ pids: [pid_t], after delay: TimeInterval) {
        let born = pids.map { ($0, started($0)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            for (child, start) in born where start != nil && started(child) == start { kill(child, SIGKILL) }
        }
    }

    /// Returns when `pid` started, in µs since 1970, or nil once there is no such process.
    public static func started(_ pid: pid_t) -> UInt64? {
        bsdinfo(pid).map { $0.pbi_start_tvsec * 1_000_000 + $0.pbi_start_tvusec }
    }

    private static func bsdinfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// Returns the parent's pid, or nil once there is no such process. It uses sysctl, which also reads another
    /// account's process (proc_pidinfo doesn't), so a walk up through root's `login` goes on to the app above it.
    public static func parent(_ pid: pid_t) -> pid_t? {
        kinfo(pid).map { $0.kp_eproc.e_ppid }
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// Returns the device of the process's controlling terminal. nil when it has none (a program started by launchd, or
    /// `setsid`), or when there is no such process.
    public static func terminal(_ pid: pid_t) -> UInt32? {
        bsdinfo(pid).map(\.e_tdev).flatMap { $0 == UInt32.max ? nil : $0 }
    }

    /// Returns the user the process runs as, or nil once there is no such process. It uses sysctl, because proc_pidinfo
    /// refuses another account's process.
    public static func owner(_ pid: pid_t) -> uid_t? { kinfo(pid).map { $0.kp_eproc.e_ucred.cr_uid } }

    /// Returns the process's arguments (its argv, program first) for a process of the same user. nil for another user's
    /// process, or when there is no such process.
    public static func arguments(_ pid: pid_t) -> [String]? {
        // 16 KB holds most programs' arguments and environment, and the system's maximum is used only when it doesn't.
        // This runs for every program in a caller's ancestry, so it shouldn't take a megabyte each. A buffer that is
        // too small isn't refused but filled with the tail of the area, argc and all, so a full buffer is read again
        // whole.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 16384
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        if size == buf.count {
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
            buf = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        }
        guard size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        // The layout is argc, then the program's path, then NULs, then argv as argc NUL-ended strings.
        var index = 4
        while index < size, buf[index] != 0 { index += 1 }
        while index < size, buf[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buf[index] != 0 { index += 1 }
            args.append(String(decoding: buf[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    /// Whether the process has ended but isn't reaped yet, so there is nothing left to stop. It asks sysctl, because
    /// `proc_pidinfo` has no answer for a zombie, so it never said yes and `stopTreeNow` waited out its grace for one.
    public static func isZombie(_ pid: pid_t) -> Bool { kinfo(pid).map { $0.kp_proc.p_stat == SZOMB } ?? false }

    /// Returns `pid` and its descendants, parents before children.
    public static func tree(_ pid: pid_t) -> [pid_t] {
        var kids = [pid_t](repeating: 0, count: 256)
        let count = Int(proc_listchildpids(pid, &kids, Int32(kids.count * MemoryLayout<pid_t>.size)))
        return [pid] + kids.prefix(max(0, count)).filter { $0 > 0 }.flatMap(tree)
    }

    /// Reads one pipe to its end on a thread of its own, and keeps the first `limit` bytes.
    private final class Reader: Sendable {
        let pipe = Pipe()
        let done = DispatchSemaphore(value: 0)
        let limit: Int
        private struct Kept { var data = Data(), truncated = false }
        private let kept = OSAllocatedUnfairLock(initialState: Kept())
        private let abandoned = OSAllocatedUnfairLock(initialState: false)
        init(_ limit: Int) { self.limit = limit }
        /// Stops reading within half a second and closes the pipe. The close happens on the reader's thread, never
        /// during a read, so no fd is reused under it.
        func abandon() { abandoned.withLock { $0 = true } }
        var data: Data { kept.withLock { $0.data } }
        var truncated: Bool { kept.withLock { $0.truncated } }
        func start() {
            let fd = pipe.fileHandleForReading.fileDescriptor
            Thread.detachNewThread { [pipe, kept, done, limit, abandoned] in
                // This uses read(2), not FileHandle.read(upToCount:), because that one waits for the whole count.
                // Output would then never arrive while a lingering child keeps the pipe open.
                var buf = [UInt8](repeating: 0, count: 1 << 16), room = limit
                var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                while true {
                    let polled = poll(&ready, 1, 500)
                    // The pipe is closed here, after the last read, because the Process holds the pipe too and it
                    // wouldn't close otherwise. It is checked on every turn, or a child that keeps writing would keep
                    // the thread for its whole life.
                    if abandoned.withLock({ $0 }) {
                        pipe.fileHandleForReading.closeQuietly()
                        break
                    }
                    if polled == 0 || (polled < 0 && errno == EINTR) { continue }
                    let count = read(fd, &buf, buf.count)
                    if count > 0 {
                        // Past the limit, output is still read and then dropped, because a full pipe would stop the
                        // program.
                        let keep = min(count, room)
                        room -= keep
                        if keep > 0 {
                            let chunk = Data(buf[0..<keep])
                            kept.withLock { $0.data.append(chunk) }
                        }
                        if keep < count { kept.withLock { $0.truncated = true } }
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                withExtendedLifetime(pipe) { _ = done.signal() }
            }
        }
    }
}
