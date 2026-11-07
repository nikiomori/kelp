import Foundation
import Core

/// An Android machine: the SDK's emulator (Hypervisor.framework, an arm64 image at full speed) on an AVD of its own in the
/// machine's folder (`avd/`, ANDROID_AVD_HOME), so the user's AVDs stay theirs. Without a window unless someone asks to see
/// it (`show` starts it again with one, from its snapshot). As a Linux or macOS machine: kelpd's `start` (each command)
/// counts as use; idle 2 minutes, its CPU stops (`adb emu avd stop`); 10, it saves its quickboot snapshot and quits.
@MainActor
final class AndroidRuntime {
    let folder: URL, machine: VMMachine
    private(set) var state: VMState
    private var emulator: Process?
    /// Whether the emulator running now was started with its window: `windowed` is what the next start asks.
    private var shown = false
    private var port = 0
    private var windowed = false
    private var lastUse = Date()
    private var ready: [(String?) -> Void] = []
    /// A sleep under way, and what wakes it once it has (a wake meanwhile would start a second emulator).
    private var saving = false, afterSave: [(String?) -> Void] = []
    private var sources: [DispatchSourceProtocol] = []

    private var serial: String { "emulator-\(port)" }
    private var avd: URL { folder.appendingPathComponent("avd") }
    private var snapshot: URL { avd.appendingPathComponent("\(machine.name).avd/snapshots/default_boot") }

    init(folder: URL, machine: VMMachine) {
        self.folder = folder
        self.machine = machine
        state = .off
        state = FileManager.default.fileExists(atPath: snapshot.path) ? .sleeping : .off
    }

    func listen() {
        // Its lock is held already (main.swift).
        sources.append(Control.listen(folder.appendingPathComponent("ctl.sock").path) { [weak self] c in self?.control(c) })
        sources += Control.run(tick: { [weak self] in self?.tick() }, leave: { [weak self] in self?.sleep { _ in exit(0) } })
        log("ready: \(machine.name) (Android), \(state.rawValue)")
    }

    private func control(_ fd: Int32) {
        Control.read(fd) { request in
            guard let request else { return self.reply(fd, "can't read the request") }
            self.handle(request) { self.reply(fd, $0) }
        }
    }

    private func reply(_ fd: Int32, _ error: String?) {
        let up = [.running, .paused, .starting].contains(state)
        let r = VMHelper.Reply(state: state, connections: 0, memoryMiB: up ? machine.memoryMiB : nil, error: error,
                               serial: state == .running ? serial : nil)
        if let d = try? Wire.line(r) { Unix.writeAll(fd, d) }
        close(fd)
    }

    private func handle(_ r: VMHelper.Request, _ done: @escaping (String?) -> Void) {
        switch r.op {
        case .status: done(nil)
        // kelpd's wake: answered as it starts; `show` first, for a boot with its window.
        case .start where r.begins:
            lastUse = Date()
            if r.beginsShown { windowed = true }
            wake { _ in }; done(nil)
        case .start: lastUse = Date(); wake(done)
        case .sleep: sleep(done)
        case .stop: stop { done(nil); exit(0) }   // off, nothing kept: the next start is the kelp-vm installed then
        case .share: done("An Android machine shares no folders: adb push and pull copy files.")
        case .screen: done("Typing into the screen is a macOS machine's.")
        case .show:
            lastUse = Date()
            windowed = true
            if emulator != nil, shown { return wake(done) }   // has its window: up, or coming up
            if emulator == nil { return wake(done) }   // down: it boots with its window
            // Started headless (an agent's run): once it's up, slept and woken again with its window.
            if state == .starting { return ready.append { _ in self.sleep { _ in self.wake(done) } } }
            sleep { _ in self.wake(done) }   // from its snapshot, now with a window
        case .quit:
            done(nil)
            stop { exit(0) }
        }
    }

    // MARK: the emulator

    private func wake(_ done: @escaping (String?) -> Void) {
        if saving { return afterSave.append(done) }
        switch state {
        case .running: done(nil)
        case .starting: ready.append(done)
        case .paused:
            Task {
                _ = try? await adb(["emu", "avd", "start"])
                state = .running
                done(nil)
            }
        case .off, .sleeping, .error, .creating:
            ready.append(done)
            boot()
        }
    }

    private func boot() {
        guard let exe = AndroidSDK.emulator else { return started(VMError("No Android SDK: install Android Studio, or set ANDROID_HOME.")) }
        state = .starting
        port = Self.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-avd", machine.name, "-port", "\(port)", "-no-audio", "-no-boot-anim", "-cores", "\(machine.cpus)",
                       "-memory", "\(machine.memoryMiB)"] + (windowed ? [] : ["-no-window"])
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_AVD_HOME"] = avd.path
        if let root = AndroidSDK.root { env["ANDROID_SDK_ROOT"] = root.path }
        p.environment = env
        let out = folder.appendingPathComponent("emulator.log")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: out) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {   // the main queue
                    guard let self, self.emulator === ended else { return }
                    self.emulator = nil
                    if self.state == .starting { self.started(VMError("The emulator quit: see emulator.log in its folder.")) }
                    if self.state != .sleeping { self.state = .off }
                }
            }
        }
        do { try p.run() } catch { return started(error) }
        emulator = p
        shown = windowed
        Task { await awaitBoot(since: Date()) }
    }

    /// Ready once Android says it finished booting.
    private func awaitBoot(since: Date) async {
        let first = !FileManager.default.fileExists(atPath: folder.appendingPathComponent("booted").path)
        while state == .starting, emulator != nil {
            if (try? await adb(["shell", "getprop", "sys.boot_completed"]))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                FileManager.default.createFile(atPath: folder.appendingPathComponent("booted").path, contents: nil)
                return started(nil)
            }
            if Date().timeIntervalSince(since) > (first ? 600 : 180) { return started(VMError("Android didn't finish booting.")) }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func started(_ error: Error?) {
        if let error {
            log("start failed: \(error.localizedDescription)")
            emulator?.terminate()
        }
        state = error == nil ? .running : .error
        lastUse = Date()
        let waiting = ready; ready = []
        waiting.forEach { $0(error?.localizedDescription) }
    }

    /// Its quickboot snapshot saved as it quits: the next start is back in seconds, where it was.
    private func sleep(_ done: @escaping (String?) -> Void) {
        guard !saving, let p = emulator, [.running, .paused].contains(state) else { return done(nil) }
        saving = true
        Task {
            if state == .paused { _ = try? await adb(["emu", "avd", "start"]) }
            _ = try? await adb(["emu", "kill"])
            for _ in 0..<120 where p.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
            if p.isRunning { p.terminate() }
            // Asleep once the emulator is gone: a wake before would have started a second one on the same AVD.
            state = .sleeping
            saving = false
            log("asleep")
            let wanted = afterSave; afterSave = []
            if !wanted.isEmpty { wake { e in wanted.forEach { $0(e) } } }
            done(nil)
        }
    }

    /// Quits it and forgets its snapshot: the next start boots afresh.
    private func stop(_ done: @escaping () -> Void) {
        let forget = { [self] in
            try? FileManager.default.removeItem(at: snapshot)
            state = .off
            done()
        }
        guard let p = emulator else { return forget() }
        Task {
            _ = try? await adb(["emu", "kill"])
            for _ in 0..<120 where p.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
            if p.isRunning { p.terminate() }
            forget()
        }
    }

    private func tick() {
        let idle = Date().timeIntervalSince(lastUse)
        if state == .running, !windowed, idle > Runtime.pauseAfter {
            Task { if (try? await adb(["emu", "avd", "stop"])) != nil, state == .running { state = .paused; log("paused") } }
        } else if state == .paused, idle > Runtime.sleepAfter {
            sleep { _ in }
        }
    }

    private func adb(_ args: [String]) async throws -> String {
        guard let adb = AndroidSDK.adb else { throw VMError("No adb: the Android SDK's platform-tools.") }
        let out = try await Subprocess.run([adb, "-s", serial] + args, cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 30)
        guard out.status == 0 else { throw VMError(String(decoding: out.stderr, as: UTF8.self)) }
        return String(decoding: out.stdout, as: UTF8.self)
    }

    /// An even console port (5554–5680) with it and the next free on this Mac: where adb finds emulators.
    nonisolated static func freePort(from start: Int = 5600) -> Int {
        func taken(_ port: Int) -> Bool {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(port).bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
            let r = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            return r == 0
        }
        return stride(from: start, through: start + 80, by: 2).first { !taken($0) && !taken($0 + 1) } ?? start
    }
}
