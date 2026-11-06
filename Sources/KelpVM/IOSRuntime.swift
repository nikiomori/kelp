import Foundation
import Core

/// An iOS machine: a simulator of the user's Xcode ("Kelp <name>", in the default device set: xcodebuild sees no other), and
/// Kelp's runner in it (`IOSRunner`, built into the machine's folder), which agents' commands reach on the Mac's loopback.
/// A simulator can't be paused or saved: idle 10 minutes, it shuts down; the next command boots it again (10–25 s).
@MainActor
final class IOSRuntime {
    let folder: URL, machine: VMMachine
    private(set) var state: VMState = .off
    private var runner: Process?
    private var port = 0
    private var lastUse = Date()
    private var ready: [(String?) -> Void] = []
    private var sources: [DispatchSourceProtocol] = []

    private var udid: String {
        (try? String(contentsOf: folder.appendingPathComponent("udid"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    init(folder: URL, machine: VMMachine) { self.folder = folder; self.machine = machine }

    func listen() {
        let lock = open(folder.appendingPathComponent("kelp-vm.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { log("another kelp-vm runs \(machine.name)"); exit(0) }
        let fd: Int32
        do { fd = try Unix.listen(folder.appendingPathComponent("ctl.sock").path) } catch { log("can't listen: \(error)"); exit(1) }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            MainActor.assumeIsolated { self?.control(c) }   // a read source on the main queue
        }
        src.resume()
        sources.append(src)
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }   // main run loop
        RunLoop.main.add(timer, forMode: .common)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.stop { exit(0) } } }   // the main queue
            s.resume()
            sources.append(s)
        }
        log("ready: \(machine.name) (iOS \(udid)), off")
    }

    private func control(_ fd: Int32) {
        Thread.detachNewThread {
            var line = Data(), byte: UInt8 = 0
            while line.count < 65536, read(fd, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
            let request = try? JSONDecoder().decode(VMHelper.Request.self, from: line)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let request else { return self.reply(fd, "can't read the request") }
                    self.handle(request) { self.reply(fd, $0) }
                }
            }
        }
    }

    private func reply(_ fd: Int32, _ error: String?) {
        let up = [.running, .starting].contains(state)
        var r = VMHelper.Reply(state: state, connections: 0, memoryMiB: up ? machine.memoryMiB : nil, error: error,
                               serial: state == .running ? udid : nil)
        r.port = state == .running ? port : nil
        if let d = try? Wire.line(r) { Unix.writeAll(fd, d) }
        close(fd)
    }

    private func handle(_ r: VMHelper.Request, _ done: @escaping (String?) -> Void) {
        switch r.op {
        case .status: done(nil)
        case .start: lastUse = Date(); wake(done)
        case .sleep, .stop: stop { done(nil); exit(0) }   // a simulator keeps no running state to save; the next start is a new kelp-vm
        case .share: done("An iOS machine shares no folders: kelp vm install takes an app from here.")
        case .screen: done("Typing into the screen is a macOS machine's.")
        case .show:
            lastUse = Date()
            wake { error in
                let simulator = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", self.udid]
                if error == nil { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: simulator) }
                done(error)
            }
        case .quit:
            done(nil)
            stop { exit(0) }
        }
    }

    private func wake(_ done: @escaping (String?) -> Void) {
        switch state {
        case .running: done(nil)
        case .starting: ready.append(done)
        default:
            ready.append(done)
            state = .starting
            Task { await boot() }
        }
    }

    /// The simulator booted (a no-op when it already is), then the runner started in it and answering.
    private func boot() async {
        do {
            _ = try await simctl(["boot", udid], allowFailure: true)
            _ = try await simctl(["bootstatus", udid, "-b"])
            guard let xctestrun = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("dd/Build/Products"),
                                                                              includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "xctestrun" })
            else { throw VMError("Kelp's runner isn't built in \(machine.name)'s folder: make the machine again.") }
            port = AndroidRuntime.freePort(from: 8700)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun.path, "-destination", "id=\(udid)"]
            var env = ProcessInfo.processInfo.environment
            env["TEST_RUNNER_KELP_PORT"] = "\(port)"
            p.environment = env
            let out = folder.appendingPathComponent("runner.log")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: out) { p.standardOutput = h; p.standardError = h }
            p.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {   // the main queue
                        guard let self, self.runner === ended else { return }
                        self.runner = nil
                        if self.state == .running { self.state = .off; log("the runner ended: see runner.log") }
                    }
                }
            }
            try p.run()
            runner = p
            let since = Date()
            while Date().timeIntervalSince(since) < 180 {
                if await ping() { return started(nil) }
                guard runner != nil else { throw VMError("Kelp's runner quit: see runner.log in \(machine.name)'s folder.") }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            throw VMError("Kelp's runner didn't answer in 3 minutes.")
        } catch { started(error) }
    }

    private func started(_ error: Error?) {
        if let error { log("start failed: \(error.localizedDescription)"); runner?.terminate() }
        state = error == nil ? .running : .error
        lastUse = Date()
        let waiting = ready; ready = []
        waiting.forEach { $0(error?.localizedDescription) }
    }

    /// The runner gone and the simulator shut down: nothing of it runs.
    private func stop(_ done: @escaping () -> Void) {
        runner?.terminate()
        runner = nil
        Task {
            _ = try? await simctl(["shutdown", udid], allowFailure: true)
            state = .off
            log("shut down")
            done()
        }
    }

    private func tick() {
        if state == .running, Date().timeIntervalSince(lastUse) > Runtime.sleepAfter { stop {} }
    }

    private func ping() async -> Bool {
        let port = port
        return await Task.detached { IOSRunnerClient.ask(port: port, ["op": "ping"])?["text"] as? String == "ok" }.value
    }

    private func simctl(_ args: [String], allowFailure: Bool = false) async throws -> String {
        let out = try await Subprocess.run(["/usr/bin/xcrun", "simctl"] + args, cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 300)
        guard out.status == 0 || allowFailure else { throw VMError("simctl \(args.first ?? ""): " + String(decoding: out.stderr, as: UTF8.self)) }
        return String(decoding: out.stdout, as: UTF8.self)
    }
}
