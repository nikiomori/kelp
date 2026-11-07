import Core
import Foundation

/// An Android machine: the SDK's emulator (Hypervisor.framework, an arm64 image at full speed) on an AVD of its own in the
/// machine's folder (`avd/`, ANDROID_AVD_HOME), so the user's AVDs stay theirs. Without a window unless someone asks to see
/// it (`show` starts it again with one, from its snapshot). As a Linux or macOS machine: kelpd's `start` (each command)
/// counts as use; idle 2 minutes, its CPU stops (`adb emu avd stop`); 10, it saves its quickboot snapshot and quits.
@MainActor
final class AndroidRuntime {
    let folder: URL, machine: VMMachine
    private(set) var state: VMState
    private var emulator: Process?
    /// The window, two facts: whether the emulator running now has one (it was booted with it), and whether the next
    /// boot gets one (Show asked; whatever ends the emulator before, its own sleep included, leaves that asked).
    private var shown = false, nextBootShown = false
    /// The user has the emulator's window: in use, never paused for idling.
    private var hasWindow: Bool { emulator != nil && shown && state != .error }   // not one that failed and is ending
    private var port = 0
    private var pausing = false, bootWhenGone = false
    /// SIGTERM came: what's under way ends, nothing new starts (a start meanwhile would leave an emulator nobody ends).
    private var leaving = false, whenSaved: [() -> Void] = []
    /// How it ends once it has left: the process's exit; a test's own.
    var exitProcess: () -> Void = { exit(0) }
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
        sources.append(
            Control.listen(folder.appendingPathComponent("ctl.sock").path) { [weak self] c in self?.control(c) })
        sources += Control.run(tick: { [weak self] in self?.tick() }, leave: { [weak self] in self?.leave() })   // SIGTERM
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
        // In use: commands through adb, and a window the user has (kelpd's memory budget sleeps only an idle machine).
        let using = state == .running ? Usage.clients(of: serial, programs: ["adb"]) + (hasWindow ? 1 : 0) : 0
        let answer = VMHelper.Reply(
            state: state, connections: using, memoryMiB: up ? machine.memoryMiB : nil, error: error,
            serial: state == .running ? serial : nil)
        if let line = try? Wire.line(answer) { Unix.writeAll(fd, line) }
        close(fd)
    }

    func handle(_ request: VMHelper.Request, _ done: @escaping (String?) -> Void) {   // internal: the tests drive it
        switch request.op {
        case .status: done(nil)
        // kelpd's wake: answered as it starts; `show` first, for a boot with its window.
        case .start where request.begins:
            lastUse = Date()
            // for a boot to come, not one up already
            if request.beginsShown, emulator == nil || saving { nextBootShown = true }
            wake { _ in }
            done(nil)
        case .start:
            lastUse = Date()
            wake(done)
        case .sleep: sleep(done)
        case .stop:
            stop {
                done(nil)
                exit(0)
            }   // off, nothing kept: the next start is the kelp-vm installed then
        case .share: done("An Android machine shares no folders: adb push and pull copy files.")
        case .screen: done("Typing into the screen is a macOS machine's.")
        case .show:
            lastUse = Date()
            // Has its window: up, or coming up (no boot to ask it of). Not one being slept: it boots again once saved.
            if hasWindow, !saving { return wake(done) }
            nextBootShown = true   // a boot is to come (off, headless, or being slept): it has the window
            if emulator == nil { return wake(done) }   // down: it boots with its window
            // Started headless (an agent's run): once it's up, slept and woken again with its window.
            if state == .starting { return ready.append { _ in self.sleep { _ in self.wake(done) } } }
            sleep { _ in self.wake(done) }   // from its snapshot, now with a window
        case .quit:
            done(nil)
            stop { exit(0) }
        }
    }

    /// SIGTERM (a logout, an install): asleep, then gone; never with an emulator left booting or saving, which would hold
    /// its AVD with nobody to end it. One booting is slept once it's up; one being saved, once it's saved.
    func leave() {   // internal: the tests drive it
        leaving = true
        if state == .starting { return ready.append { [weak self] _ in self?.leave() } }
        if saving { return whenSaved.append { [weak self] in self?.leave() } }
        sleep { [weak self] _ in self?.exitProcess() }
    }

    // MARK: the emulator

    private func wake(_ done: @escaping (String?) -> Void) {
        if leaving { return done("Kelp's machine helper is stopping: start it again in a moment.") }
        if saving { return afterSave.append(done) }
        switch state {
        case .running: done(nil)
        case .starting: ready.append(done)
        case .paused:
            Task {
                do { _ = try await adb(["emu", "avd", "start"]) } catch {
                    return done("It didn't go on after its pause: \(error.localizedDescription)")
                }
                // Slept meanwhile (kelpd's budget, `kelp vm sleep`): woken from where that left it, not taken for running.
                guard state == .paused, !saving else { return wake(done) }
                state = .running
                done(nil)
            }
        case .off, .sleeping, .error, .creating:
            ready.append(done)
            // One that failed may still be ending (`started` terminated it): a second on its AVD would fail on the lock.
            if emulator != nil { bootWhenGone = true } else { boot() }
        }
    }

    private func boot() {
        guard let exe = AndroidSDK.emulator else {
            nextBootShown = false   // no boot to have it: a later one isn't asked of by a Show that was told this failed
            return started(VMError("No Android SDK: install Android Studio, or set ANDROID_HOME."))
        }
        state = .starting
        port = Self.freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments =
            [
                "-avd", machine.name, "-port", "\(port)", "-no-audio", "-no-boot-anim", "-cores", "\(machine.cpus)",
                "-memory", "\(machine.memoryMiB)"
            ] + (nextBootShown ? [] : ["-no-window"])
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_AVD_HOME"] = avd.path
        if let root = AndroidSDK.root { env["ANDROID_SDK_ROOT"] = root.path }
        process.environment = env
        let out = folder.appendingPathComponent("emulator.log")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        if let logFile = try? FileHandle(forWritingTo: out) {
            process.standardOutput = logFile
            process.standardError = logFile
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {   // the main queue
                    guard let self, self.emulator === ended else { return }
                    self.emulator = nil   // its window went with it (closed, slept, quit): the next boot has one only if Show asks
                    if self.bootWhenGone {
                        self.bootWhenGone = false
                        self.state = .off
                        return self.boot()
                    }
                    if self.state == .starting {
                        self.started(VMError("The emulator quit: see emulator.log in its folder."))
                    }
                    if self.state != .sleeping { self.state = .off }
                }
            }
        }
        do { try process.run() } catch {
            nextBootShown = false
            return started(error)
        }
        emulator = process
        shown = nextBootShown
        nextBootShown = false
        Task { await awaitBoot(since: Date()) }
    }

    /// Ready once Android says it finished booting.
    private func awaitBoot(since: Date) async {
        let first = !FileManager.default.fileExists(atPath: folder.appendingPathComponent("booted").path)
        while state == .starting, emulator != nil {
            if (try? await adb(["shell", "getprop", "sys.boot_completed"]))?.trimmingCharacters(
                in: .whitespacesAndNewlines) == "1"
            {
                FileManager.default.createFile(atPath: folder.appendingPathComponent("booted").path, contents: nil)
                return started(nil)
            }
            if Date().timeIntervalSince(since) > (first ? 600 : 180) {
                return started(VMError("Android didn't finish booting."))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func started(_ error: Error?) {
        if let error {
            log("start failed: \(error.localizedDescription)")
            emulator?.terminate()
            // One wedged (why it didn't finish booting) may not heed SIGTERM: killed after a while, so a retry can boot.
            if let pid = emulator?.processIdentifier { Subprocess.killLater([pid], after: 10) }
        }
        state = error == nil ? .running : .error
        lastUse = Date()
        let waiting = ready
        ready = []
        waiting.forEach { $0(error?.localizedDescription) }
    }

    /// Its quickboot snapshot saved as it quits: the next start is back in seconds, where it was.
    private func sleep(_ done: @escaping (String?) -> Void) {
        guard !saving, let process = emulator, [.running, .paused].contains(state) else { return done(nil) }
        saving = true
        Task {
            if state == .paused { _ = try? await adb(["emu", "avd", "start"]) }
            _ = try? await adb(["emu", "kill"])
            for _ in 0..<120 where process.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
            if process.isRunning { process.terminate() }
            // Asleep once the emulator is gone: a wake before would have started a second one on the same AVD.
            state = .sleeping
            saving = false
            log("asleep")
            let wanted = afterSave
            afterSave = []
            // told it's stopping, when it's leaving
            if !wanted.isEmpty { wake { error in wanted.forEach { $0(error) } } }
            let saved = whenSaved
            whenSaved = []
            saved.forEach { $0() }
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
        guard let process = emulator else { return forget() }
        Task {
            _ = try? await adb(["emu", "kill"])
            for _ in 0..<120 where process.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
            if process.isRunning { process.terminate() }
            forget()
        }
    }

    private func tick() {
        if state == .running, Usage.clients(of: serial, programs: ["adb"]) > 0 { lastUse = Date() }   // a command through adb (`kelp vm run`) is use
        let idle = Date().timeIntervalSince(lastUse)
        if state == .running, !hasWindow, !pausing, idle > Runtime.pauseAfter {
            pausing = true
            Task {
                defer { pausing = false }
                guard (try? await adb(["emu", "avd", "stop"])) != nil else { return }
                // A start while it stopped is answered running: it goes on, not paused under that caller's command.
                if state == .running, Date().timeIntervalSince(lastUse) > Runtime.pauseAfter {
                    state = .paused
                    log("paused")
                } else {
                    do { _ = try await adb(["emu", "avd", "start"]) } catch {
                        log("couldn't go on after a start: \(error)")
                        if state == .running { state = .paused }   // stopped it is: the next wake tries again (not a later state)
                    }
                }
            }
        } else if state == .paused, idle > Runtime.sleepAfter {
            sleep { _ in }
        }
    }

    private func adb(_ args: [String]) async throws -> String {
        guard let adb = AndroidSDK.adb else { throw VMError("No adb: the Android SDK's platform-tools.") }
        let out = try await Subprocess.run(
            [adb, "-s", serial] + args, cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 30)
        guard out.status == 0 else { throw VMError(String(decoding: out.stderr, as: UTF8.self)) }
        return String(decoding: out.stdout, as: UTF8.self)
    }

    /// An even console port (5554–5680) with it and the next free on this Mac: where adb finds emulators.
    nonisolated static func freePort(from start: Int = 5600) -> Int {
        func taken(_ port: Int) -> Bool {
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
        return stride(from: start, through: start + 80, by: 2).first { !taken($0) && !taken($0 + 1) } ?? start
    }
}
