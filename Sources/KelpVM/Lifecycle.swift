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
