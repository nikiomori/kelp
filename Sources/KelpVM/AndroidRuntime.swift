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
    /// What time it is: the clock's; a test's, moved past the idle limits.
    var now: () -> Date = { Date() }
    private var lastUse = Date()
    private var ready: [(String?) -> Void] = []
    /// A sleep under way, and what wakes it once it has (a wake meanwhile would start a second emulator).
    private var saving = false, afterSave: [(String?) -> Void] = []
    private var sources: [DispatchSourceProtocol] = []

    private var serial: String { "emulator-\(port)" }
    private var avd: URL { VMFolder(folder).avd }
    private var snapshot: URL { VMFolder(folder).snapshot(machine.name) }

    init(folder: URL, machine: VMMachine) {
        self.folder = folder
        self.machine = machine
        state = VMFolder(folder).restingState(machine)
    }

    func listen() {
        // Its lock is held already (main.swift).
        sources.append(
            Control.listen(VMFolder(folder).control.path) { [weak self] fd in
                guard let self else { return }
                Control.serve(fd, handle: handle, reply: reply)
            })
        sources += Control.run(tick: { [weak self] in self?.tick() }, leave: { [weak self] in self?.leave() })   // SIGTERM
        log("ready: \(machine.name) (Android), \(state.rawValue)")
    }

    /// In use: commands through adb, and a window the user has (kelpd's memory budget sleeps only an idle machine).
    /// Limit: a command kelpd just answered a start for isn't seen until its adb runs, a few milliseconds on.
    private var using: Int {
        state == .running ? Usage.clients(of: serial, programs: ["adb"]) + (hasWindow ? 1 : 0) : 0
    }

    private func reply(_ fd: Int32, _ error: String?) {
        let up = state.isUp
        let answer = VMHelper.Reply(
            state: state, connections: using, memoryMiB: up ? machine.memoryMiB : nil, error: error,
            serial: state == .running ? serial : nil)
        Control.write(fd, answer)
    }

    func handle(_ request: VMHelper.Request, _ done: @escaping (String?) -> Void) {   // internal: the tests drive it
        switch request.op {
        case .status: done(nil)
        // kelpd's wake: answered as it starts; `show` first, for a boot with its window.
        case .start where request.begins:
            lastUse = now()
            // for a boot to come, not one up already
            if request.beginsShown, emulator == nil || saving { nextBootShown = true }
            wake { _ in }
            done(nil)
        case .start:
            lastUse = now()
            wake(done)
        // The budget's (`if-idle`): asked of one that was idle a moment ago, refused if it's in use by now.
        case .sleep where Lifecycle.refusesSleep(request, inUse: using > 0): done("\(machine.name) is in use.")
        case .sleep: sleep(done)
        case .stop:
            stop {
                done(nil)
                self.exitProcess()
            }   // off, nothing kept: the next start is the kelp-vm installed then
        case .share, .screen: done(Lifecycle.unsupported(request.op, machine))
        case .show:
            lastUse = now()
            // Has its window: up, or coming up (no boot to ask it of). Not one being slept: it boots again once saved.
            if hasWindow, !saving { return wake(done) }
            nextBootShown = true   // a boot is to come (off, headless, or being slept): it has the window
            if emulator == nil { return wake(done) }   // down: it boots with its window
            // From its snapshot, now with a window; one that couldn't be slept is still up without one, and Show is told.
            let again = {
                self.sleep { error in
                    guard let error, [.running, .paused].contains(self.state) else { return self.wake(done) }
                    done(error)
                }
            }
            // Started headless (an agent's run): once it's up, slept and woken again with its window.
            if state == .starting { return ready.append { _ in again() } }
            again()
        case .quit:
            if let refused = Lifecycle.refusesQuit(request, hasVM: emulator != nil, state: state, name: machine.name) {
                return done(refused)
            }
            done(nil)
            stop { self.exitProcess() }
        }
    }

    /// SIGTERM (a logout, an install): asleep, then gone; never with an emulator left booting or saving, which would hold
    /// its AVD with nobody to end it. One booting is slept once it's up; one being saved, once it's saved.
    func leave() {   // internal: the tests drive it
        leaving = true
        if state == .starting { return ready.append { [weak self] _ in self?.leave() } }
        if saving { return whenSaved.append { [weak self] in self?.leave() } }
        sleep { [weak self] error in
            guard let self else { return }
            // One that couldn't be slept is still up: quit as a stop does, not left with nobody to end it.
            guard error != nil, emulator != nil else { return exitProcess() }
            stop { self.exitProcess() }
        }
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
        // A kelp-vm that was killed took no leave: its emulator holds the AVD, and a second one on it would quit.
        Lifecycle.endLeftover(in: folder, "emulator")
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
        do {
            let logFile = try FileHandle(forWritingTo: out)
            process.standardOutput = logFile
            process.standardError = logFile
        } catch { log("no emulator.log: \(error.localizedDescription)") }
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
        Lifecycle.remember(process, in: folder, as: "emulator")
        shown = nextBootShown
        nextBootShown = false
        Task { await awaitBoot(since: now()) }
    }

    /// Ready once Android says it finished booting.
    private func awaitBoot(since: Date) async {
        let first = !FileManager.default.fileExists(atPath: VMFolder(folder).booted.path)
        while state == .starting, emulator != nil {
            if (try? await adb(["shell", "getprop", "sys.boot_completed"]))?.trimmingCharacters(
                in: .whitespacesAndNewlines) == "1"
            {
                FileManager.default.createFile(atPath: VMFolder(folder).booted.path, contents: nil)
                return started(nil)
            }
            if now().timeIntervalSince(since) > (first ? 600 : 180) {
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
        lastUse = now()
        let waiting = ready
        ready = []
        waiting.forEach { $0(error?.localizedDescription) }
    }

    /// Its quickboot snapshot saved as it quits: the next start is back in seconds, where it was. Not saved, it says
    /// why, and is left where the next request finds it: still up, or off.
    private func sleep(_ done: @escaping (String?) -> Void) {
        guard !saving, let process = emulator, [.running, .paused].contains(state) else { return done(nil) }
        saving = true
        Task {
            if state == .paused, await tell(["emu", "avd", "start"]) { state = .running }
            let error = await save(process)
            saving = false
            // Still up without its window: no later boot is asked of it by the Show that waited for this one.
            // Limit: a Show that came while it saved is woken below and answered as for a start, with no window.
            if error != nil, emulator != nil { nextBootShown = false }
            log(error ?? "asleep")
            let wanted = afterSave
            afterSave = []
            // told it's stopping, when it's leaving
            if !wanted.isEmpty { wake { error in wanted.forEach { $0(error) } } }
            let saved = whenSaved
            whenSaved = []
            saved.forEach { $0() }
            done(error)
        }
    }

    /// The emulator told to quit with its snapshot, and the state that leaves, set here alone: asleep once it's gone
    /// and its snapshot is there (a wake before would have started a second one on the same AVD); else why not.
    /// Saved is read from its snapshot's files, written since it was told (the emulator says nothing of it itself).
    private func save(_ process: Process) async -> String? {
        let since = Date().addingTimeInterval(-1)   // the files' clock, not the idle one; a second for their resolution
        let told = await tell(["emu", "kill"])
        guard told || !process.isRunning else {
            lastUse = now()   // still up: a tick tries again once it has idled anew, not every 5 s
            return "\(machine.name) couldn't be told to sleep (adb didn't reach its emulator): it's still up."
        }
        guard await gone(process) else {
            await end(process)
            state = .off
            return "\(machine.name)'s emulator didn't quit in 30 s and was ended: its state isn't saved."
        }
        guard written(since: since) else {
            state = .off
            return "\(machine.name)'s emulator quit without saving its state: the next start boots it."
        }
        state = .sleeping
        return nil
    }

    /// Whether a file of its snapshot was written since `since`: an old snapshot left from the sleep before isn't this one.
    private func written(since: Date) -> Bool {
        let files = FileManager.default.enumerator(
            at: snapshot, includingPropertiesForKeys: [.contentModificationDateKey])
        return files?.contains { file in
            ((try? (file as? URL)?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                .map { $0 >= since } ?? false
        } ?? false
    }

    /// Whether the emulator quit within 30 s of being told to.
    private func gone(_ process: Process) async -> Bool {
        let until = now().addingTimeInterval(30)
        while process.isRunning, now() < until { try? await Task.sleep(nanoseconds: 250_000_000) }
        return !process.isRunning
    }

    /// One that didn't quit when told: SIGTERM, then SIGKILL, waited for (kelp-vm may end right after, and a SIGKILL
    /// left for later would never come).
    private func end(_ process: Process) async {
        let pid = process.processIdentifier
        await Task.detached { Subprocess.stopTreeNow(pid) }.value
    }

    /// Quits it and forgets its snapshot: the next start boots afresh.
    private func stop(_ done: @escaping () -> Void) {
        let forget = { [self] in
            FileManager.default.removeIfAny(snapshot)
            state = .off
            done()
        }
        guard let process = emulator else { return forget() }
        Task {
            // Not told (adb didn't reach it), it isn't waited for.
            let quit = await tell(["emu", "kill"])
            if !quit { await end(process) } else if await !gone(process) { await end(process) }
            forget()
        }
    }

    func tick() {   // internal: the tests drive it
        if state == .running, Usage.clients(of: serial, programs: ["adb"]) > 0 { lastUse = now() }   // a command through adb (`kelp vm run`) is use
        switch Lifecycle.idleStep(state, idle: now().timeIntervalSince(lastUse), inUse: hasWindow) {
        case .pause where !pausing:
            pausing = true
            Task {
                defer { pausing = false }
                guard await tell(["emu", "avd", "stop"]) else { return }   // not stopped: the next tick tries again
                // A start while it stopped is answered running: it goes on, not paused under that caller's command.
                if state == .running, now().timeIntervalSince(lastUse) > Runtime.pauseAfter {
                    state = .paused
                    log("paused")
                } else {
                    do { _ = try await adb(["emu", "avd", "start"]) } catch {
                        log("couldn't go on after a start: \(error)")
                        if state == .running { state = .paused }   // stopped it is: the next wake tries again (not a later state)
                    }
                }
            }
        case .sleep: sleep { _ in }
        case .pause, nil: break
        }
    }

    /// `adb` for what it's told to do (quit, stop, resume): whether it was; its failure logged.
    @discardableResult private func tell(_ args: [String]) async -> Bool {
        do {
            _ = try await adb(args)
            return true
        } catch {
            log("adb \(args.joined(separator: " ")): \(error.localizedDescription)")
            return false
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
