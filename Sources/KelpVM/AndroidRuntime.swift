import Core
import Foundation

/// Runs an Android machine. The machine is the SDK's emulator (Hypervisor.framework, running an arm64 image at full
/// speed) on an AVD of its own in the machine's folder (`avd/`, ANDROID_AVD_HOME), so the user's own AVDs stay
/// untouched. It runs without a window unless someone asks to see it, and then `show` starts it again with one, from
/// its snapshot. As with a Linux or macOS machine, kelpd's `start` (sent with each command) counts as use. After 2
/// idle minutes its CPU stops (`adb emu avd stop`), and after 10 it saves its quickboot snapshot and quits.
@MainActor
final class AndroidRuntime: MachineRuntime {
    let folder: URL, machine: VMMachine
    private(set) var state: VMState
    private var emulator: Process?
    /// Two facts about the window. `shown` says whether the emulator running now has one (it was booted with it).
    /// `nextBootShown` says whether the next boot gets one, because Show asked. Whatever ends the emulator before that
    /// boot, its own sleep included, leaves that request in place.
    private var shown = false, nextBootShown = false
    /// Whether the user has the emulator's window. The machine is then in use and is never paused for idling.
    private var hasWindow: Bool { emulator != nil && shown && state != .error }   // not a failed one that's ending
    private var port = 0
    /// The claim on the emulator's port (`Lifecycle.claimPort`). It is held while the port may be in use, and let go
    /// when the next boot claims a port.
    private var portClaim: Int32 = -1
    private var pausing = false, bootWhenGone = false
    /// Set when SIGTERM came. What's under way ends and nothing new starts, because a start meanwhile would leave an
    /// emulator that nobody ends.
    private var leaving = false, whenSaved: [() -> Void] = []
    /// How kelp-vm ends once the machine has left. By default the process exits, and a test sets its own.
    var exitProcess: () -> Void = { exit(0) }
    /// What time it is. It is the clock by default, and a test sets its own, moved past the idle limits.
    var now: () -> Date = { Date() }
    private var lastUse = Date()
    private var ready: [(String?) -> Void] = []
    /// `saving` is a sleep under way, and `afterSave` holds the wakes to run once it's done, because a wake meanwhile
    /// would start a second emulator.
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
        // main.swift already holds the machine's lock.
        sources.append(
            Control.listen(VMFolder(folder).control.path) { [weak self] fd in
                guard let self else { return }
                Control.serve(fd, handle: handle, reply: reply)
            })
        // `leave` runs on SIGTERM or SIGINT.
        sources += Control.run(tick: { [weak self] in self?.tick() }, leave: { [weak self] in self?.leave() })
        log("ready: \(machine.name) (Android), \(state.rawValue)")
    }

    /// Counts what uses the machine: commands through adb, a window the user has, and a start kelpd answered in the
    /// last `startWindow`, because that start's command runs adb right after. kelpd's memory budget sleeps only an idle
    /// machine.
    private var using: Int {
        guard state == .running else { return 0 }
        let started = now().timeIntervalSince(lastStart) < Self.startWindow ? 1 : 0
        return Usage.clients(of: serial, programs: ["adb"]) + (hasWindow ? 1 : 0) + started
    }
    static let startWindow: TimeInterval = 10
    private var lastStart = Date.distantPast

    private func reply(_ fd: Int32, _ error: String?) {
        let up = state.isUp
        let answer = VMHelper.Reply(
            state: state, connections: using, memoryMiB: up ? machine.memoryMiB : nil, error: error,
            serial: state == .running ? serial : nil)
        Control.write(fd, answer)
    }

    func handle(_ request: VMHelper.Request, _ done: @escaping (String?) -> Void) {   // internal: the tests drive it
        Lifecycle.handle(request, on: self, done)
    }

    var hasMachine: Bool { emulator != nil }
    var inUse: Bool { using > 0 }
    func end() { exitProcess() }

    func used(_ request: VMHelper.Request) {
        lastUse = now()
        if request.op == .start, !request.begins { lastStart = lastUse }   // its command runs adb next (`using`)
        // kelpd's wake that asks for the window applies to a boot still to come, not to an emulator already up
        if request.beginsShown, emulator == nil || saving { nextBootShown = true }
    }

    func sleep(_ request: VMHelper.Request, _ done: @escaping (String?) -> Void) { sleep(done) }

    func show(_ done: @escaping (String?) -> Void) {
        // The emulator already has its window, up or coming up, so there is no boot to ask for it. That doesn't hold
        // for one being slept, because it boots again once it's saved.
        if hasWindow, !saving { return wake(done) }
        nextBootShown = true   // a boot is to come (off, headless, or being slept), and it gets the window
        if emulator == nil { return wake(done) }   // the emulator is down, so it boots with its window
        // The emulator boots again from its snapshot, now with a window. One that couldn't be slept is still up
        // without a window, and Show is told why.
        let again = {
            self.sleep { error in
                guard let error, [.running, .paused].contains(self.state) else { return self.wake(done) }
                done(error)
            }
        }
        // An emulator started headless (for an agent's run) is slept once it's up, and woken again with its window.
        if state == .starting { return ready.append { _ in again() } }
        again()
    }

    func quit() { stop { self.exitProcess() } }

    /// Handles SIGTERM (a logout, an install) by putting the machine to sleep and then ending kelp-vm. It never leaves
    /// an emulator booting or saving, because that would hold its AVD with nobody to end it. A booting emulator is
    /// slept once it's up, and one being saved once it's saved.
    func leave() {   // internal: the tests drive it
        leaving = true
        if state == .starting { return ready.append { [weak self] _ in self?.leave() } }
        if saving { return whenSaved.append { [weak self] in self?.leave() } }
        sleep { [weak self] error in
            guard let self else { return }
            guard let process = emulator, process.isRunning else { return exitProcess() }
            // An emulator that couldn't be slept is still up. It is quit as a stop does, so it isn't left with nobody
            // to end it.
            if error != nil { return stop { self.exitProcess() } }
            // An emulator that failed is still running (`started` is ending it, or it boots again once gone). Its
            // process tree is ended before kelp-vm goes.
            Task {
                await self.end(process)
                self.exitProcess()
            }
        }
    }

    // MARK: the emulator

    func wake(_ done: @escaping (String?) -> Void) {
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
                // When the machine was slept meanwhile (kelpd's budget, `kelp vm sleep`), it is woken from where that
                // left it, not taken for running.
                guard state == .paused, !saving else { return wake(done) }
                Lifecycle.move(&state, to: .running)
                done(nil)
            }
        case .off, .sleeping, .error, .creating:
            ready.append(done)
            // An emulator that failed may still be ending (`started` terminated it), and a second emulator on its AVD
            // would fail on the lock.
            if emulator != nil { bootWhenGone = true } else { boot() }
        }
    }

    private func boot() {
        guard let exe = AndroidSDK.emulator else {
            nextBootShown = false   // so a Show that hears of this failure doesn't ask a later boot for a window
            return started(VMError("No Android SDK: install Android Studio, or set ANDROID_HOME."))
        }
        Lifecycle.move(&state, to: .starting)
        // A kelp-vm that was killed didn't clean up, so its emulator may still hold the AVD, and a second emulator on
        // it would quit.
        Lifecycle.endLeftover(in: folder, "emulator")
        close(portClaim)
        (port, portClaim) = Lifecycle.claimPort(from: 5600, in: folder.deletingLastPathComponent())
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
                MainActor.assumeIsolated {   // DispatchQueue.main runs this on the main thread
                    guard let self, self.emulator === ended else { return }
                    // The window went with the emulator (closed, slept, quit), so the next boot has one only if Show
                    // asks.
                    self.emulator = nil
                    if self.bootWhenGone {
                        self.bootWhenGone = false
                        Lifecycle.move(&self.state, to: .off)
                        if !self.leaving { return self.boot() }   // when leaving, waiters hang up as kelp-vm goes
                    }
                    if self.state == .starting {
                        self.started(VMError("The emulator quit: see emulator.log in its folder."))
                    }
                    if self.state != .sleeping { Lifecycle.move(&self.state, to: .off) }
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

    /// Marks the machine ready once Android says it finished booting.
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
            // The emulator's whole process tree is ended, because the emulator runs qemu under it. A wedged emulator
            // (the reason it didn't finish booting) may not heed SIGTERM, so it is killed after a while and a retry
            // can boot.
            if let process = emulator { Task { await end(process, grace: 10) } }
        }
        Lifecycle.move(&state, to: error == nil ? .running : .error)
        lastUse = now()
        ready.flush(error)
    }

    /// Saves the emulator's quickboot snapshot as it quits, so the next start is back in seconds, where it was. When
    /// the snapshot isn't saved, `done` gets the reason, and the machine is left as the next request finds it, still
    /// up or off.
    private func sleep(_ done: @escaping (String?) -> Void) {
        guard !saving, let process = emulator, [.running, .paused].contains(state) else { return done(nil) }
        saving = true
        Task {
            if state == .paused, await tell(["emu", "avd", "start"]) { Lifecycle.move(&state, to: .running) }
            let error = await save(process)
            saving = false
            // The emulator is still up without its window, so the Show that waited for this sleep no longer asks a
            // later boot for one.
            // Limit: a Show that came while it saved is woken below and answered as for a start, with no window.
            if error != nil, emulator != nil { nextBootShown = false }
            log(error ?? "asleep")
            let wanted = afterSave
            afterSave = []
            // when kelp-vm is leaving, these wakes are told it's stopping
            if !wanted.isEmpty { wake { error in wanted.forEach { $0(error) } } }
            let saved = whenSaved
            whenSaved = []
            saved.forEach { $0() }
            done(error)
        }
    }

    /// Tells the emulator to quit with its snapshot, and sets the resulting state, here alone. The machine is asleep
    /// once the emulator is gone and its snapshot is there (a wake before that would have started a second emulator
    /// on the same AVD). Otherwise this returns why not. Whether it saved is read from the snapshot's files written
    /// since it was told, because the emulator itself says nothing about it.
    private func save(_ process: Process) async -> String? {
        let since = Date().addingTimeInterval(-1)   // file clock, not the idle one, less a second for its resolution
        let told = await tell(["emu", "kill"])
        guard told || !process.isRunning else {
            lastUse = now()   // the emulator stays up, so ticks retry after it idles again, not every 5 s
            return "\(machine.name) couldn't be told to sleep (adb didn't reach its emulator): it's still up."
        }
        guard await gone(process) else {
            await end(process)
            Lifecycle.move(&state, to: .off)
            return "\(machine.name)'s emulator didn't quit in 30 s and was ended: its state isn't saved."
        }
        guard written(since: since) else {
            Lifecycle.move(&state, to: .off)
            return "\(machine.name)'s emulator quit without saving its state: the next start boots it."
        }
        Lifecycle.move(&state, to: .sleeping)
        return nil
    }

    /// Returns whether a file of the snapshot was written since `since`, because an old snapshot left by the sleep
    /// before isn't this one.
    private func written(since: Date) -> Bool {
        let files = FileManager.default.enumerator(atPath: snapshot.path)
        return files?.contains { name in
            (name as? String).flatMap { FileManager.default.modified(snapshot.appendingPathComponent($0).path) }
                .map { $0 >= since } ?? false
        } ?? false
    }

    /// Whether the emulator quit within 30 s of being told to.
    private func gone(_ process: Process) async -> Bool {
        let until = now().addingTimeInterval(30)
        while process.isRunning, now() < until { try? await Task.sleep(nanoseconds: 250_000_000) }
        return !process.isRunning
    }

    /// Ends an emulator that didn't quit when told, with SIGTERM and then SIGKILL, and waits for it. kelp-vm may end
    /// right after, and a SIGKILL left for later would never come.
    private func end(_ process: Process, grace: TimeInterval = 2) async {
        let pid = process.processIdentifier
        await Task.detached { Subprocess.stopTreeNow(pid, grace: grace) }.value
    }

    /// Quits the emulator and forgets its snapshot, so the next start boots afresh.
    func stop(_ done: @escaping () -> Void) {
        let forget = { [self] in
            FileManager.default.removeIfAny(snapshot)
            Lifecycle.move(&state, to: .off)
            done()
        }
        guard let process = emulator else { return forget() }
        Task {
            // When adb didn't reach the emulator, it isn't waited for but ended at once.
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
                // A start that came while the CPU stopped was answered as running, so the machine goes on rather than
                // pausing under that caller's command.
                if state == .running, Lifecycle.staysPaused(idle: now().timeIntervalSince(lastUse), inUse: hasWindow) {
                    Lifecycle.move(&state, to: .paused)
                    log("paused")
                } else {
                    do { _ = try await adb(["emu", "avd", "start"]) } catch {
                        log("couldn't go on after a start: \(error)")
                        // The CPU did stop, so a running machine is marked paused and the next wake tries again. A
                        // later state is left alone.
                        if state == .running { Lifecycle.move(&state, to: .paused) }
                    }
                }
            }
        case .sleep: sleep { _ in }
        case .pause, nil: break
        }
    }

    /// Runs `adb` to tell the emulator to do something (quit, stop, resume). Returns whether that worked, and logs a
    /// failure.
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
}
