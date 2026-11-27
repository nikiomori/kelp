import Core
import Foundation

/// A kind of machine that kelp-vm runs: `Runtime` for Linux and macOS, `AndroidRuntime` and `IOSRuntime`. The protocol
/// holds what each kind does its own way. Which request does what is the same for every kind (`Lifecycle.handle`).
@MainActor protocol MachineRuntime: AnyObject {
    var machine: VMMachine { get }
    var state: VMState { get }
    /// Whether a VM, an emulator or a runner is there (up, or ending). A quit for a new size is refused while one is.
    var hasMachine: Bool { get }
    /// Whether the machine is in use now (a connection, a command, a window the user has). kelpd's memory budget
    /// sleeps only an idle machine.
    var inUse: Bool { get }
    /// Counts a start or a Show as use when it comes.
    func used(_ request: VMHelper.Request)
    /// Brings the machine up (booted, woken or resumed), then calls `done`.
    func wake(_ done: @escaping (String?) -> Void)
    /// Puts the machine to sleep and answers through `done`. A sleep the budget asks for gets here only when it wasn't
    /// refused for use. kelp-vm may end after the sleep.
    func sleep(_ request: VMHelper.Request, _ done: @escaping (String?) -> Void)
    /// Turns the machine off and keeps nothing, so the next start boots afresh.
    func stop(_ done: @escaping () -> Void)
    /// Shows the machine's screen, then calls `done`.
    func show(_ done: @escaping (String?) -> Void)
    /// Takes the machine down as a quit does (after the quit is answered), then ends kelp-vm.
    func quit()
    /// Ends kelp-vm. Normally the process exits, and a test sets its own way to end.
    func end()
    func listen()
}

/// What kelp-vm decides about its machine from the machine's state. It is kept apart from Virtualization so that it can
/// be tested (KelpVMTests), and the runtimes ask it.
enum Lifecycle {
    /// Handles a request from kelpd the same way for every kind of machine. What a kind does its own way is up to its
    /// runtime (`MachineRuntime`).
    @MainActor static func handle(
        _ request: VMHelper.Request, on runtime: some MachineRuntime, _ done: @escaping (String?) -> Void
    ) {
        switch request.op {
        case .status: done(nil)
        case .start:
            runtime.used(request)
            guard request.begins else { return runtime.wake(done) }
            runtime.wake { _ in }
            done(nil)   // kelpd's wake is answered as it starts, while the boot goes on
        // The budget's sleep (`if-idle`) is asked of a machine that was idle a moment ago, and refused if it's in
        // use by now.
        case .sleep where refusesSleep(request, inUse: runtime.inUse): done("\(runtime.machine.name) is in use.")
        case .sleep: runtime.sleep(request, done)
        case .stop:
            runtime.stop {
                done(nil)
                runtime.end()
            }   // nothing is kept, so the next start runs the kelp-vm installed then
        case .share, .screen: done(unsupported(request.op, runtime.machine))
        case .show:
            runtime.used(request)
            runtime.show(done)
        case .quit:
            let name = runtime.machine.name
            if let refused = refusesQuit(request, hasVM: runtime.hasMachine, state: runtime.state, name: name) {
                return done(refused)
            }
            done(nil)
            runtime.quit()
        }
    }

    /// Moves a runtime's state. Every move goes through here alone (ArchitectureTests counts the writes). A move that
    /// `moves` doesn't allow is logged and refused, and the state is left as it was. A runtime's first state is read
    /// off its folder and set as the runtime is made.
    static func move(_ state: inout VMState, to next: VMState) {
        guard allowed(state, next) else { return log("refused a move from \(state.rawValue) to \(next.rawValue)") }
        state = next
    }

    /// Where each state may go besides off and error, which any state may go to (a stop, its process gone, a failure
    /// reported). A machine comes up only through starting, pauses only while up, and goes to sleep from up or off.
    /// Sleep from off is allowed because an Android emulator told to sleep quits, so it's off before its snapshot is
    /// found saved.
    static let moves: [VMState: Set<VMState>] = [
        .creating: [.starting], .off: [.starting, .sleeping], .sleeping: [.starting], .error: [.starting],
        .starting: [.running], .running: [.paused, .sleeping], .paused: [.starting, .running, .sleeping]
    ]

    static func allowed(_ from: VMState, _ to: VMState) -> Bool {
        from == to || to == .off || to == .error || moves[from]?.contains(to) == true
    }

    /// Returns why a quit asked `ifDown` (before a new size is written) is refused, or nil when it isn't. It is refused
    /// when the machine runs or a boot is under way, because a boot tried again has no VM for a second and is still
    /// starting. Every kind's runtime asks this.
    static func refusesQuit(_ request: VMHelper.Request, hasVM: Bool, state: VMState, name: String) -> String? {
        request.quitsIfDown && (hasVM || state == .starting)
            ? "\(name) is in use again: shut it down, then change its size." : nil
    }

    /// Returns the answer every runtime gives when its kind of machine can't do `op`, or nil when it can. Only Linux
    /// and macOS machines share folders. kelp-vm drives a macOS machine's screen, and kelpd drives the screen of an
    /// Android or iOS machine (`vm.screen`).
    static func unsupported(_ op: VMHelper.Request.Operation, _ machine: VMMachine) -> String? {
        switch op {
        case .share where !machine.kind.sharesFolders:
            "\(machine.name) shares no folders: kelp vm install takes an app to it."
        case .screen where machine.kind != .macos:
            machine.kind.hasScreen
                ? "\(machine.name)'s screen is kelpd's to drive, not its kelp-vm's." : "\(machine.name) has no screen."
        default: nil
        }
    }

    /// Returns whether kelp-vm ends once a sleep is answered. It ends when the sleep didn't fail, the machine is down
    /// (saved, or never up), and it isn't starting (a boot tried again, or a boot a command asked for meanwhile).
    static func endsAfterSleep(error: String?, hasVM: Bool, state: VMState) -> Bool {
        error == nil && !hasVM && state != .starting
    }

    /// Returns whether a sleep that kelpd's memory budget asks for (`if-idle`) is refused. It is refused when the
    /// machine is in use by now, though it wasn't when the budget looked. The user's own sleep is never refused.
    static func refusesSleep(_ request: VMHelper.Request, inUse: Bool) -> Bool { request.ifIdle && inUse }

    /// Notes a process (an emulator, an iOS runner, kelp-vm itself) in the machine's folder, with its pid and when it
    /// started. A kelp-vm that's killed can't clean up as it leaves, so the next kelp-vm for the machine ends the
    /// children the killed one left (`endLeftover`), and kelpd can end a kelp-vm that no longer answers
    /// (`VMService.quit`).
    static func remember(_ pid: pid_t, in folder: URL, as name: String) {
        let note = "\(pid) \(Subprocess.started(pid) ?? 0)"
        do {
            try note.write(to: VMFolder(folder).child(name), atomically: true, encoding: .utf8)
        } catch { log("can't note \(name)'s pid: \(error.localizedDescription)") }
    }

    /// Ends the child an earlier kelp-vm noted, if it still runs (`VMFolder.endChild`). This is called under the
    /// machine's lock, so the child can't belong to another kelp-vm that is running.
    static func endLeftover(in folder: URL, _ name: String) {
        if let pid = VMFolder(folder).endChild(name) { log("ended \(name) \(pid), left by a kelp-vm that was killed") }
    }

    /// Claims a loopback port for an emulator or a runner, together with the port after it (an emulator's adb port).
    /// The port is every second one from `start`, and nothing listens on either port. It is claimed from every other
    /// kelp-vm by a lock on `<machines>/.ports/<port>`, held on `fd` until the fd is closed or kelp-vm ends. Probing
    /// alone once let two machines woken seconds apart take the same port, before either emulator listened on it. When
    /// no port is free, this returns `start` unclaimed (fd -1).
    static func claimPort(from start: Int, in machines: URL) -> (port: Int, fd: Int32) {
        let claims = machines.appendingPathComponent(".ports")
        do { try Paths.ensure(claims) } catch { log("no \(claims.path): \(error.localizedDescription)") }
        for port in stride(from: start, through: start + 80, by: 2) where !listened(port) && !listened(port + 1) {
            let fd = open(claims.appendingPathComponent("\(port)").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return (port, fd) }
            close(fd)
        }
        return (start, -1)
    }

    private static func listened(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        return Unix.connect(fd, loopbackPort: port)
    }

    enum IdleStep { case pause, sleep }

    /// Returns what a tick does with a machine nobody used for `idle` seconds. A running machine pauses after
    /// `Runtime.pauseAfter`, and a paused one sleeps after `Runtime.sleepAfter`. A machine in use (a connection, a
    /// window the user has) stays as it is.
    static func idleStep(_ state: VMState, idle: TimeInterval, inUse: Bool) -> IdleStep? {
        guard !inUse else { return nil }
        if state == .running, idle > Runtime.pauseAfter { return .pause }
        if state == .paused, idle > Runtime.sleepAfter { return .sleep }
        return nil
    }

    /// Returns whether a pause that a tick asked for still stands once it's done, or the machine goes on running. A
    /// command that came while the machine paused was answered as running (and made the machine in use, or newly
    /// used), so the machine isn't paused under it.
    static func staysPaused(idle: TimeInterval, inUse: Bool) -> Bool {
        idleStep(.running, idle: idle, inUse: inUse) == .pause
    }

    /// Holds the machine's folder for this kelp-vm by locking `kelp-vm.lock`, which `VMService.alive` checks. It tries
    /// for half a second, because a size being written or kelpd's check holds the lock for a moment. The fd stays open
    /// while kelp-vm runs. Returns nil when another kelp-vm holds the lock.
    static func hold(_ folder: URL, tries: Int = 10) -> Int32? {
        let fd = open(VMFolder(folder).lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        for attempt in 0...tries {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            if attempt < tries { usleep(50_000) }
        }
        close(fd)
        return nil
    }
}

/// kelp-vm's control socket (`ctl.sock`). kelpd sends one request as a line and waits for one reply.
enum Control {
    /// Reads the request on `fd` on a thread of its own, so a slow client never holds the main queue. It hands the
    /// request to `answer` on the main actor, or nil when the request couldn't be read.
    static func read(_ fd: Int32, _ answer: @escaping @MainActor @Sendable (VMHelper.Request?) -> Void) {
        Thread.detachNewThread {
            var line = Data(), buf = [UInt8](repeating: 0, count: 4096)
            while line.count < 65536, !line.contains(0x0A) {
                let count = Darwin.read(fd, &buf, buf.count)
                guard count > 0 else { break }
                line.append(contentsOf: buf[0..<count])
            }
            let request = line.split(separator: 0x0A, omittingEmptySubsequences: false).first
                .flatMap { try? JSONDecoder().decode(VMHelper.Request.self, from: Data($0)) }
            DispatchQueue.main.async { MainActor.assumeIsolated { answer(request) } }   // this runs on the main thread
        }
    }

    /// Reads the request on `fd` and hands it to `handle`, whose answer (an error, or nil) goes to `reply`.
    static func serve(
        _ fd: Int32, handle: @escaping @MainActor @Sendable (VMHelper.Request, @escaping (String?) -> Void) -> Void,
        reply: @escaping @MainActor @Sendable (Int32, String?) -> Void
    ) {
        read(fd) { request in
            guard let request else { return reply(fd, "can't read the request") }
            handle(request) { reply(fd, $0) }
        }
    }

    /// Writes `answer` to `fd` as one line and closes the connection.
    static func write(_ fd: Int32, _ answer: VMHelper.Reply) {
        if let line = try? Wire.line(answer) { Unix.writeAll(fd, line) }
        close(fd)
    }
}

extension Control {
    /// Listens on a socket at `path` and hands each connection it accepts to `accepted` on the main actor. The caller
    /// keeps the returned source. When it can't listen, kelp-vm ends, and kelpd starts another.
    @MainActor
    static func listen(_ path: String, _ accepted: @escaping @MainActor (Int32) -> Void) -> any DispatchSourceRead {
        let fd: Int32
        do { fd = try Unix.listen(path) } catch {
            log("can't listen on \(path): \(error)")
            exit(1)
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Unix.noSigPipe(client)
            MainActor.assumeIsolated { accepted(client) }   // a read source on the main queue
        }
        src.resume()
        return src
    }

    /// Calls `tick` every 5 s, and `leave` on SIGTERM or SIGINT (an install, a logout), both on the main actor. The
    /// caller keeps the returned signal sources.
    @MainActor
    static func run(tick: @escaping @MainActor () -> Void, leave: @escaping @MainActor () -> Void)
        -> [any DispatchSourceSignal]
    {
        // The timer fires on the main run loop, so on the main thread.
        let timer = Timer(timeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        return [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { leave() } }   // the source fires on the main queue
            source.resume()
            return source
        }
    }
}

extension Array where Element == (String?) -> Void {
    /// Tells each waiting start how it went (nil means running). The list is emptied first, so a start asked again
    /// meanwhile waits anew.
    mutating func flush(_ error: Error?) {
        let waiting = self
        self = []
        waiting.forEach { $0(error?.localizedDescription) }
    }
}
