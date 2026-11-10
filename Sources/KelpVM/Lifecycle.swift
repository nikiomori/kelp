import Core
import Foundation

/// What kelp-vm decides about its machine from where the machine is, apart from Virtualization so it can be tested
/// (KelpVMTests): the runtimes ask these.
enum Lifecycle {
    /// A quit asked `if-down` (a new size is to be written) refused: the machine runs, or a boot is under way (one tried
    /// again has no VM for a second, and is still starting).
    static func refusesQuit(_ args: [String]?, hasVM: Bool, state: VMState) -> Bool {
        args == ["if-down"] && (hasVM || state == .starting)
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
        let pid = process.processIdentifier
        let note = "\(pid) \(Subprocess.started(pid) ?? 0)"
        do {
            try note.write(to: folder.appendingPathComponent(name + ".child"), atomically: true, encoding: .utf8)
        } catch { log("can't note \(name)'s pid: \(error.localizedDescription)") }
    }

    /// Ends the child an earlier kelp-vm noted, if it still runs (the same process, by its start time): SIGTERM, then
    /// SIGKILL, before this returns. Called under the machine's lock, so it's nobody else's.
    static func endLeftover(in folder: URL, _ name: String) {
        let note = folder.appendingPathComponent(name + ".child")
        guard let words = String(contentsIfAny: note)?.split(separator: " "), words.count == 2,
            let pid = pid_t(words[0]), let start = UInt64(words[1])
        else { return }
        FileManager.default.removeIfAny(note)
        guard start != 0, Subprocess.started(pid) == start else { return }
        log("ending \(name) \(pid), left by a kelp-vm that was killed")
        Subprocess.stopTreeNow(pid)
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

    /// The machine's folder held for this kelp-vm (`kelp-vm.lock`, `VMService.alive`): tried for half a second, as a size
    /// being written or kelpd's look holds it a moment. The fd stays open while kelp-vm runs; nil: another one has it.
    static func hold(_ folder: URL, tries: Int = 10) -> Int32? {
        let fd = open(folder.appendingPathComponent("kelp-vm.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
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
