import Core
import Foundation

/// A kind of machine kelp-vm runs (Linux and macOS: `Runtime`; `AndroidRuntime`; `IOSRuntime`): what each does its own
/// way. Which request does what is the same for every kind, `Lifecycle.handle`.
@MainActor protocol MachineRuntime: AnyObject {
    var machine: VMMachine { get }
    var state: VMState { get }
    /// A VM, an emulator or a runner is there (up, or ending): a quit for a new size is refused while it is.
    var hasMachine: Bool { get }
    /// In use now (a connection, a command, a window the user has): kelpd's memory budget sleeps an idle machine only.
    var inUse: Bool { get }
    /// A start or a Show counted as use, as it comes.
    func used(_ request: VMHelper.Request)
    /// Up (booted, woken, resumed), then `done`.
    func wake(_ done: @escaping (String?) -> Void)
    /// A sleep (the budget's not refused for use), answered by `done`; kelp-vm may end after it.
    func sleep(_ request: VMHelper.Request, _ done: @escaping (String?) -> Void)
    /// Off, nothing kept: the next start boots afresh.
    func stop(_ done: @escaping () -> Void)
    /// Its screen shown, then `done`.
    func show(_ done: @escaping (String?) -> Void)
    /// Down as a quit takes it (after its answer), then kelp-vm ends.
    func quit()
    /// kelp-vm ends: the process's exit, a test's own.
    func end()
    func listen()
}

/// What kelp-vm decides about its machine from where the machine is, apart from Virtualization so it can be tested
/// (KelpVMTests): the runtimes ask these.
enum Lifecycle {
    /// kelpd's request, the same for every kind; what's a kind's own is its runtime's (`MachineRuntime`).
    @MainActor static func handle(
        _ request: VMHelper.Request, on runtime: some MachineRuntime, _ done: @escaping (String?) -> Void
    ) {
        switch request.op {
        case .status: done(nil)
        case .start:
            runtime.used(request)
            guard request.begins else { return runtime.wake(done) }
            runtime.wake { _ in }
            done(nil)   // kelpd's wake: answered as it starts, the boot going on
        // The budget's (`if-idle`): asked of one that was idle a moment ago, refused if it's in use by now.
        case .sleep where refusesSleep(request, inUse: runtime.inUse): done("\(runtime.machine.name) is in use.")
        case .sleep: runtime.sleep(request, done)
        case .stop:
            runtime.stop {
                done(nil)
                runtime.end()
            }   // nothing kept: the next start is the kelp-vm installed then
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

    /// Every move of a runtime's state, here alone (ArchitectureTests counts the writes): one `moves` doesn't allow is
    /// logged and refused, the state left as it was. Its first state, read off its folder, is set as it's made.
    static func move(_ state: inout VMState, to next: VMState) {
        guard allowed(state, next) else { return log("refused a move from \(state.rawValue) to \(next.rawValue)") }
        state = next
    }

    /// Where each state may go besides off and error, which any may (a stop, its process gone, a failure told): up
    /// only through starting, paused only from up, asleep from up or off (an Android emulator told to sleep quits, so
    /// it's off, before its snapshot is found saved).
    static let moves: [VMState: Set<VMState>] = [
        .creating: [.starting], .off: [.starting, .sleeping], .sleeping: [.starting], .error: [.starting],
        .starting: [.running], .running: [.paused, .sleeping], .paused: [.starting, .running, .sleeping]
    ]

    static func allowed(_ from: VMState, _ to: VMState) -> Bool {
        from == to || to == .off || to == .error || moves[from]?.contains(to) == true
    }

    /// A quit asked `ifDown` (a new size is to be written) refused, and why: the machine runs, or a boot is under way
    /// (one tried again has no VM for a second, and is still starting). Every kind's runtime asks it.
    static func refusesQuit(_ request: VMHelper.Request, hasVM: Bool, state: VMState, name: String) -> String? {
        request.quitsIfDown && (hasVM || state == .starting)
            ? "\(name) is in use again: shut it down, then change its size." : nil
    }

    /// What a machine of this kind doesn't do, the same answer from each runtime: nil when it does. Folders are a Linux
    /// or macOS machine's; kelp-vm drives a macOS machine's screen, kelpd an Android or iOS one's (`vm.screen`).
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

    /// Whether kelp-vm ends once a sleep is answered: the machine is down (saved, or never up), not starting (a boot tried
    /// again, or one a command asked for meanwhile).
    static func endsAfterSleep(error: String?, hasVM: Bool, state: VMState) -> Bool {
        error == nil && !hasVM && state != .starting
    }

    /// A sleep kelpd's memory budget asks (`if-idle`) refused: the machine is in use by now, which it wasn't when the
    /// budget looked. The user's own sleep is never refused.
    static func refusesSleep(_ request: VMHelper.Request, inUse: Bool) -> Bool { request.ifIdle && inUse }

    /// A child (an emulator, an iOS runner) noted in the machine's folder, its pid and when it started: a kelp-vm
    /// that's killed takes no leave, and the next one for the machine ends what that left (`endLeftover`).
    static func remember(_ process: Process, in folder: URL, as name: String) {
        remember(process.processIdentifier, in: folder, as: name)
    }

    /// A process noted as `remember` notes a child: kelp-vm itself, for kelpd to end one that no longer answers
    /// (`VMService.quit`).
    static func remember(_ pid: pid_t, in folder: URL, as name: String) {
        let note = "\(pid) \(Subprocess.started(pid) ?? 0)"
        do {
            try note.write(to: VMFolder(folder).child(name), atomically: true, encoding: .utf8)
        } catch { log("can't note \(name)'s pid: \(error.localizedDescription)") }
    }

    /// Ends the child an earlier kelp-vm noted, if it still runs (`VMFolder.endChild`). Called under the machine's lock,
    /// so it's nobody else's.
    static func endLeftover(in folder: URL, _ name: String) {
        if let pid = VMFolder(folder).endChild(name) { log("ended \(name) \(pid), left by a kelp-vm that was killed") }
    }

    /// A loopback port for an emulator or a runner, with the one after it (an emulator's adb port): even, from `start`,
    /// nothing listening on either, and claimed from every other kelp-vm by a lock on `<machines>/.ports/<port>`, held on
    /// `fd` until it's closed or kelp-vm ends. Probing alone let two machines woken seconds apart take the same port,
    /// neither's emulator listening on it yet. None free: `start`, unclaimed (fd -1).
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
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    enum IdleStep { case pause, sleep }

    /// What a tick does with a machine nobody used for `idle` seconds: a running one pauses after `Runtime.pauseAfter`,
    /// a paused one sleeps after `Runtime.sleepAfter`; one in use (a connection, a window the user has) stays.
    static func idleStep(_ state: VMState, idle: TimeInterval, inUse: Bool) -> IdleStep? {
        guard !inUse else { return nil }
        if state == .running, idle > Runtime.pauseAfter { return .pause }
        if state == .paused, idle > Runtime.sleepAfter { return .sleep }
        return nil
    }

    /// A pause asked by a tick, done: whether it stands, or the machine goes on. A command that came while it paused
    /// was answered running (and made it in use, or newly used), and isn't paused under.
    static func staysPaused(idle: TimeInterval, inUse: Bool) -> Bool {
        idleStep(.running, idle: idle, inUse: inUse) == .pause
    }

    /// The machine's folder held for this kelp-vm (`kelp-vm.lock`, `VMService.alive`): tried for half a second, as a size
    /// being written or kelpd's look holds it a moment. The fd stays open while kelp-vm runs; nil: another one has it.
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

/// kelp-vm's control socket (`ctl.sock`): kelpd sends one request a line and waits for one reply.
enum Control {
    /// The request on `fd`, read on a thread of its own (a slow client never holds the main queue), handed to `answer`
    /// on the main actor; nil when it couldn't be read.
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
            DispatchQueue.main.async { MainActor.assumeIsolated { answer(request) } }   // the main queue
        }
    }

    /// The request on `fd` read and handed to `handle`, whose answer (an error, or nil) goes to `reply`.
    static func serve(
        _ fd: Int32, handle: @escaping @MainActor @Sendable (VMHelper.Request, @escaping (String?) -> Void) -> Void,
        reply: @escaping @MainActor @Sendable (Int32, String?) -> Void
    ) {
        read(fd) { request in
            guard let request else { return reply(fd, "can't read the request") }
            handle(request) { reply(fd, $0) }
        }
    }

    /// `answer` written to `fd` as one line, and the connection closed.
    static func write(_ fd: Int32, _ answer: VMHelper.Reply) {
        if let line = try? Wire.line(answer) { Unix.writeAll(fd, line) }
        close(fd)
    }
}

extension Control {
    /// A socket at `path`, each connection it accepts handed to `accepted` on the main actor; the source is the caller's to
    /// keep. Can't listen: kelp-vm ends (kelpd starts another).
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

    /// `tick` every 5 s, and `leave` on SIGTERM or SIGINT (an install, a logout), both on the main actor; the signal
    /// sources are the caller's to keep.
    @MainActor
    static func run(tick: @escaping @MainActor () -> Void, leave: @escaping @MainActor () -> Void)
        -> [any DispatchSourceSignal]
    {
        let timer = Timer(timeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { tick() } }   // main run loop
        RunLoop.main.add(timer, forMode: .common)
        return [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { leave() } }   // the main queue
            source.resume()
            return source
        }
    }
}

extension Array where Element == (String?) -> Void {
    /// Each start waiting told how it went (nil: running): the list emptied first, so one asked again waits anew.
    mutating func flush(_ error: Error?) {
        let waiting = self
        self = []
        waiting.forEach { $0(error?.localizedDescription) }
    }
}
