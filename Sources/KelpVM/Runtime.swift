import AppKit
import Core
import Virtualization

/// One line to stdout, which kelpd sends to the machine's helper.log.
func log(_ message: String) { print("\(Date().formatted(.iso8601)) \(message)") }

/// The machine and its connections. Everything here runs on the main queue: the VM's (VZVirtualMachine's default) and
/// the sockets' handlers alike.
@MainActor
final class Runtime: NSObject, VZVirtualMachineDelegate, NSWindowDelegate {
    let folder: URL, machine: VMMachine
    private var vm: VZVirtualMachine?
    private(set) var state: VMState
    /// The folder in each share slot (`VMs.shareSlots`, also in shares.json), and when each was last asked for.
    private var shares: [Int: String]
    private var shareUse: [Int: Date] = [:]
    /// Agents' and people's SSH connections open now; none for a while, and it pauses, then sleeps.
    private var connections = 0
    /// `screen` calls under way (an agent reading or driving a macOS machine's screen).
    private var screening = 0
    /// In use: a connection, its window on screen (the user works in it), its screen read or driven. kelpd's memory
    /// budget sleeps an idle machine only, and no tick pauses one that isn't.
    private var using: Int {
        connections + (window?.isVisible == true ? 1 : 0) + (screening > 0 || Screen.turn != nil ? 1 : 0)
    }
    private var lastUse = Date()
    private var ready: [(String?) -> Void] = [], stopped: [() -> Void] = []
    /// A save under way (`sleep`): who waits for it to end (another sleep), and what wakes it right after (a command came).
    private var saving = false, saveDone: [(String?) -> Void] = [], afterSave: [(String?) -> Void] = []
    /// When a save last failed: not tried again by itself for 10 minutes (a full disk would take gigabytes each 5 s).
    private var saveFailed: Date?
    private var targetMiB: Int
    private var sockets: [Int: VZVirtioSocketConnection] = [:]
    private var nextSocket = 0
    private var ticks = 0
    /// What it cost the Mac at the last tick, while it runs (`Usage`).
    private var usage: (cpu: Double?, memoryMiB: Int)?
    /// Starts tried in a row: a macOS machine's storage can stay locked a moment after its installer (or a stop) ends.
    private var tries = 0
    private var listeners: [DispatchSourceRead] = [], signals: [DispatchSourceSignal] = []
    /// Its screen, when someone asked to see it (`show`): while it's open the machine counts as in use.
    var window: NSWindow?   // internal: a test gives it one
    /// How it ends once it has left: the process's exit; a test's own.
    var exitProcess: () -> Void = { exit(0) }
    /// What time it is: the clock's; a test's, moved past the idle limits.
    var now: () -> Date = { Date() }

    nonisolated static let pauseAfter: TimeInterval = 120, sleepAfter: TimeInterval = 600
    private var saved: URL { paths.savedState }
    /// Its files kelpd reads and writes too.
    private var paths: VMFolder { VMFolder(folder) }
    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    init(folder: URL) throws {
        self.folder = folder
        machine = try JSONDecoder().decode(
            VMMachine.self, from: Data(contentsOf: VMFolder(folder).machine))
        shares =
            (try? JSONDecoder().decode(
                [Int: String].self, from: Data(contentsOf: VMFolder(folder).shares))) ?? [:]
        state =
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("state.vzsave").path)
            ? .sleeping : .off
        targetMiB = machine.memoryMiB
        super.init()
    }

    // MARK: sockets

    func listen() {
        // Its lock is held already (main.swift): two starts at once would both launch one, and the second would take the sockets over.
        listeners.append(Control.listen(paths.ssh.path) { [weak self] fd in self?.connect(fd, counted: true) })
        listeners.append(Control.listen(paths.own.path) { [weak self] fd in self?.connect(fd, counted: false) })
        listeners.append(Control.listen(paths.control.path) { [weak self] fd in self?.control(fd) })
        // A signal: saved (what runs inside goes on at the next wake), then gone.
        signals = Control.run(tick: { [weak self] in self?.tick() }, leave: { [weak self] in self?.leave() })
        log("ready: \(machine.name), \(state.rawValue)")
    }

    /// An SSH connection: wakes the machine, then joins the client to the guest's sshd (vsock port 22 on Linux; on macOS,
    /// whose sshd listens on TCP only, /usr/bin/nc to its NAT address: `MacGuest.bridge`).
    private func connect(_ client: Int32, counted: Bool) {
        if counted {
            connections += 1
            lastUse = now()
        }
        let join: (String?) -> Void = { [self] error in
            guard error == nil else { return finish(client, counted) }
            if machine.kind == .macos {
                guard let ip = guestAddress(), MacGuest.bridge(client, to: ip, ended: { self.finish(client, counted) })
                else {
                    log("can't reach sshd")
                    return finish(client, counted)
                }
                return
            }
            sshd { fd, id in
                guard let fd else {
                    log("can't reach sshd")
                    return self.finish(client, counted)
                }
                self.pump(client, fd, id, counted)
            }
        }
        // Kelp's own reads come while it starts (the clock, before it counts as ready): they don't wait for it, nor wake it.
        if counted { wake(join) } else { join(vm == nil ? "asleep" : nil) }
    }

    /// A Linux guest's sshd, on vsock port 22: the connection kept under `id` until it's let go (`release`).
    private func sshd(_ done: @escaping @MainActor @Sendable (Int32?, Int?) -> Void) {
        guard let dev = vm?.socketDevices.first as? VZVirtioSocketDevice else { return done(nil, nil) }
        dev.connect(toPort: 22) { result in
            MainActor.assumeIsolated {   // VZ answers on the VM's queue, the main one
                guard case .success(let conn) = result else { return done(nil, nil) }
                self.nextSocket += 1
                self.sockets[self.nextSocket] = conn
                done(conn.fileDescriptor, self.nextSocket)
            }
        }
    }

    private func release(_ fd: Int32, _ id: Int?) {
        if let id { sockets.removeValue(forKey: id)?.close() } else { close(fd) }
    }

    /// A macOS guest's address, from the leases of the Mac's NAT network.
    private func guestAddress() -> String? {
        guard let mac = String(contentsIfAny: file("mac")) else { return nil }
        return MacGuest.address(mac: mac.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func pump(_ client: Int32, _ guest: Int32, _ id: Int?, _ counted: Bool) {
        let both = DispatchGroup()
        for (from, to) in [(client, guest), (guest, client)] {
            both.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = read(from, &buf, buf.count)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 || !Unix.writeAll(to, Data(buf[0..<count])) { break }
                }
                shutdown(to, SHUT_WR)
                both.leave()
            }
        }
        both.notify(queue: .main) {
            MainActor.assumeIsolated {   // notify on the main queue
                self.release(guest, id)
                self.finish(client, counted)
            }
        }
    }

    private func finish(_ client: Int32, _ counted: Bool) {
        close(client)
        if counted {
            connections -= 1
            lastUse = now()
        }
    }

    /// kelpd's requests: one JSON line in, one out.
    private func control(_ fd: Int32) {
        Control.read(fd) { request in
            guard let request else { return self.reply(fd, "can't read the request") }
            self.handle(request) { error, slot in self.reply(fd, error, slot: slot) }
        }
    }

    /// Internal: the tests drive it.
    func handle(_ request: VMHelper.Request, _ done: @escaping (String?, Int?) -> Void) {
        switch request.op {
        case .status: done(nil, nil)
        // `begin` (kelpd's wake, holding its lock): starting is answered at once, the boot goes on.
        case .start where request.begins:
            lastUse = now()
            wake { _ in }
            done(nil, nil)
        case .start:
            lastUse = now()
            wake { done($0, nil) }
        // Asleep or off, nothing is kept here (the state is on disk): it ends, and the next start is the kelp-vm Kelp has
        // then, an update's included. Its answer is written before (`reply` writes and closes).
        // Ends only once its machine is down: one still starting isn't put to sleep (`sleep` answers at once), and ending
        // then would cut its power.
        // Starting covers a boot tried again in a second (`awaitSSH`), with no VM meanwhile.
        // The budget's (`if-idle`): asked of one that was idle a moment ago, refused if it's in use by now (a command
        // that connected since, a window opened).
        case .sleep where Lifecycle.refusesSleep(request, inUse: using > 0):
            done("\(machine.name) is in use.", nil)
        case .sleep:
            sleep { error in
                done(error, nil)
                if Lifecycle.endsAfterSleep(error: error, hasVM: self.vm != nil, state: self.state) { self.leaveSoon() }
            }
        case .stop:
            stop {
                done(nil, nil)
                self.leaveSoon()
            }
        case .show:
            lastUse = now()
            wake { error in
                if error == nil { self.show() }
                done(error, nil)
            }
        case .screen:
            guard machine.kind == .macos else { return done("Its screen is a macOS machine's.", nil) }
            lastUse = now()
            wake { error in
                guard error == nil else { return done(error, nil) }
                guard let view = self.screen() else { return done("The machine has no screen yet.", nil) }
                self.screening += 1
                Screen.run(request.args ?? [], session: request.session ?? "-", view: view) {
                    self.screening -= 1
                    self.lastUse = self.now()
                    done($0, nil)
                }
            }
        case .quit:
            // `if-down` (a new size): not while it runs, which a command may have woken it to since it was asked.
            // Starting with no VM for a moment is a boot tried again (`awaitSSH`): in use too.
            if Lifecycle.refusesQuit(request.args, hasVM: vm != nil, state: state) {
                return done("\(machine.name) is in use again: shut it down, then change its size.", nil)
            }
            done(nil, nil)
            guard let vm else { return leaveSoon() }
            vm.stop { _ in self.leaveSoon() }
        case .share:
            guard let path = request.path else { return done("share: a path", nil) }
            let free = shares.first { $0.value == path }?.key ?? (0..<VMs.shareSlots).first { shares[$0] == nil }
            // A folder taken from its slot goes stale under whatever runs in it: only an idle machine gives one up.
            guard free != nil || connections == 0 else {
                return done(
                    "\(VMs.shareSlots) folders are shared with \(machine.name) and commands run in it: try again when they end.",
                    nil)
            }
            let slot =
                free ?? (0..<VMs.shareSlots).min { shareUse[$0] ?? .distantPast < shareUse[$1] ?? .distantPast } ?? 0
            shareUse[slot] = Date()
            guard shares[slot] != path else { return done(nil, slot) }
            shares[slot] = path
            do { try JSONEncoder().encode(shares).write(to: paths.shares) } catch {
                return done("\(error)", nil)
            }
            if let dev = vm?.directorySharingDevices.first(where: {
                ($0 as? VZVirtioFileSystemDevice)?.tag == "kelp\(slot)"
            }) as? VZVirtioFileSystemDevice {
                dev.share = VZSingleDirectoryShare(
                    directory: VZSharedDirectory(url: URL(fileURLWithPath: path), readOnly: false))
            }
            done(nil, slot)
        }
    }

    /// Ends once what this turn of the main queue answers is written: a stop or a sleep that waited for a save is told
    /// in the same turn as the sleep it waited for, after that one's reply.
    private func leaveSoon() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.exitProcess() } }   // the main queue
    }

    private func reply(_ fd: Int32, _ error: String?, slot: Int? = nil) {
        Control.write(fd, answer(error, slot: slot))
    }

    /// Internal: the tests read it.
    func answer(_ error: String?, slot: Int? = nil) -> VMHelper.Reply {
        var answer = VMHelper.Reply(
            state: state, connections: using, memoryMiB: vm == nil ? nil : usage?.memoryMiB ?? targetMiB,
            error: error, slot: slot)
        answer.screen = Screen.turn
        answer.cpu = vm == nil ? nil : usage?.cpu
        return answer
    }

    // MARK: the machine

    private func wake(_ done: @escaping (String?) -> Void) {
        if saving { return afterSave.append(done) }   // resumed under a save, it would run on as the save ends it
        switch state {
        case .running: done(nil)
        case .starting: ready.append(done)
        case .paused:
            ready.append(done)
            state = .starting
            vm?.resume { r in MainActor.assumeIsolated { self.started(r.failure) } }   // the VM's queue
        case .off, .sleeping, .error, .creating:
            ready.append(done)
            boot()
        }
    }

    private func boot() {
        state = .starting
        targetMiB = machine.memoryMiB   // a new machine, restored or booted, has all of it: `adjustMemory` sets its balloon again
        let vm: VZVirtualMachine
        do { vm = VZVirtualMachine(configuration: try configuration()) } catch { return started(error) }
        vm.delegate = self
        self.vm = vm
        (window?.contentView as? VZVirtualMachineView)?.virtualMachine = vm
        guard FileManager.default.fileExists(atPath: saved.path) else {
            #if arch(arm64)   // a macOS machine's configuration doesn't build on Intel (`MacGuest.needsAppleSilicon`)
                if machine.kind == .macos, !FileManager.default.fileExists(atPath: paths.booted.path) {
                    // The first boot: macOS sets the account up, signs in and turns Remote Login on by itself.
                    do {
                        let password = try String(contentsOf: paths.password, encoding: .utf8).trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        let options = try MacGuest.firstStart(machine, password: password)
                        return vm.start(options: options) { error in
                            MainActor.assumeIsolated { self.awaitSSH(restored: false, error: error) }
                        }
                    } catch { return started(error) }
                }
            #endif
            return vm.start { result in
                MainActor.assumeIsolated { self.awaitSSH(restored: false, error: result.failure) }
            }
        }
        #if arch(arm64)
            vm.restoreMachineStateFrom(url: saved) { error in
                MainActor.assumeIsolated {
                    FileManager.default.removeIfAny(self.saved)   // a saved state restores once
                    if let error {   // from an older macOS, or damaged: boot instead
                        log("restore failed, booting: \(error.localizedDescription)")
                        return vm.start { result in
                            MainActor.assumeIsolated { self.awaitSSH(restored: false, error: result.failure) }
                        }
                    }
                    // The guest's balloon comes back inflated while the Mac maps all of its memory again: let it go, so that
                    // inflating it anew (`adjustMemory`) hands those pages back.
                    let balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
                    balloon?.targetVirtualMachineMemorySize = UInt64(self.machine.memoryMiB) << 20
                    vm.resume { r in MainActor.assumeIsolated { self.awaitSSH(restored: true, error: r.failure) } }
                }
            }
        #else
            // Limit: Intel saves no machine state (Virtualization does on Apple silicon only), so a saved one can't be there.
            FileManager.default.removeIfAny(saved)
            vm.start { r in MainActor.assumeIsolated { self.awaitSSH(restored: false, error: r.failure) } }
        #endif
    }

    /// Ready once sshd answers with its banner (on Linux systemd's sshd-vsock socket listens before sshd can answer; a
    /// macOS guest's first boot sets itself up for minutes before Remote Login is on).
    private func awaitSSH(restored: Bool, error: Error?, since: Date = Date()) {
        if let error, error.localizedDescription.contains("lock"), tries < 20 {
            tries += 1
            vm = nil
            return DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.boot() } }
        }
        tries = 0
        if let error { return started(error) }
        guard vm != nil else {   // shut down while it started: not a failure
            let waiting = ready
            ready = []
            return waiting.forEach { $0("\(machine.name) was shut down while it started.") }
        }
        let firstBoot = !FileManager.default.fileExists(atPath: paths.booted.path)
        guard Date().timeIntervalSince(since) < (firstBoot ? 1800 : 180) else {
            return started(VMError("sshd didn't answer"))
        }
        if machine.kind == .macos {
            let ip = guestAddress()
            return Thread.detachNewThread {
                let ok = ip.map(MacGuest.banner) ?? false
                DispatchQueue.main.async { MainActor.assumeIsolated { self.answered(ok, restored, since) } }
            }
        }
        sshd { fd, id in
            guard let fd else { return self.retry(restored, since) }
            Thread.detachNewThread {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0), buf = [UInt8](repeating: 0, count: 4)
                let ok = poll(&pfd, 1, 3000) > 0 && read(fd, &buf, 4) == 4 && buf == Array("SSH-".utf8)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.release(fd, id)
                        self.answered(ok, restored, since)
                    }
                }
            }
        }
    }

    /// sshd answered (or not yet): ready once its one command ran (a clock make and friends compare times by, ~/Kelp).
    private func answered(_ ok: Bool, _ restored: Bool, _ since: Date) {
        guard ok else { return retry(restored, since) }
        FileManager.default.createFile(atPath: paths.booted.path, contents: nil)
        // Restored: its clock set to now. Booted: its exchange folder made ~/Kelp (a restore keeps that).
        let command = restored ? setClock() : VMs.filesSetup(os: machine.kind)
        Task {
            do { _ = try await own(command) } catch { log("\(command): \(error.localizedDescription)") }
            started(nil)
        }
    }

    private func retry(_ restored: Bool, _ since: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (machine.kind == .macos ? 1 : 0.2)) {
            MainActor.assumeIsolated { self.awaitSSH(restored: restored, error: nil, since: since) }
        }
    }

    private func started(_ error: Error?) {
        if let error {
            log("start failed: \(error.localizedDescription)")
            vm?.stop { _ in }   // half started holds its memory and disk for nothing
            vm = nil
        }
        state = error == nil ? .running : .error
        lastUse = now()
        let waiting = ready
        ready = []
        waiting.forEach { $0(error?.localizedDescription) }
        if error == nil { adjustMemory() }
    }

    private func down() {
        vm = nil
        state = .off
        let waiting = stopped
        stopped = []
        waiting.forEach { $0() }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            log("the guest shut down")
            down()
        }   // the VM's queue, the main one
    }
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            log("stopped: \(error.localizedDescription)")
            down()
            state = .error
        }
    }

    /// Every 5 s: no connection for `pauseAfter`, and it pauses; for `sleepAfter`, it goes to disk. While it runs, its
    /// memory follows what the guest uses every 15 s.
    private func tick() {
        ticks += 1
        usage = vm == nil ? nil : Usage.sample()
        if using > 0 { lastUse = now() }   // idle from when the window closed, not from before it was opened
        let idle = now().timeIntervalSince(lastUse)
        switch Lifecycle.idleStep(state, idle: idle, inUse: using > 0) {
        case .pause:
            vm?.pause { result in
                MainActor.assumeIsolated {
                    if result.failure == nil, self.state == .running {
                        self.state = .paused
                        log("paused")
                    }
                }
            }
        case .sleep where now().timeIntervalSince(saveFailed ?? .distantPast) > 600:
            sleep { error in
                if Lifecycle.endsAfterSleep(error: error, hasVM: self.vm != nil, state: self.state) { self.leaveSoon() }
            }   // as `.sleep` does
        case .sleep: break   // its save failed a moment ago
        case nil: if state == .running, ticks % 3 == 0 { adjustMemory() }
        }
    }

    // MARK: inside

    /// The balloon gives the Mac back what the guest doesn't use (`VMs.memoryTarget`). A restore maps all of `memoryMiB`;
    /// this takes it back.
    private func adjustMemory() {
        guard machine.kind == .linux else { return }   // a macOS guest has no /proc/meminfo, and keeps all it was given
        Task {
            guard let text = try? await own("cat /proc/meminfo") else { return }
            func kb(_ key: String) -> Int? {
                text.split(separator: "\n").first { $0.hasPrefix(key + ":") }?.split(separator: " ").dropFirst().first
                    .flatMap { Int($0) }
            }
            guard let total = kb("MemTotal"), let available = kb("MemAvailable"), state == .running,
                let balloon = vm?.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
            else { return }
            let target = VMs.memoryTarget(
                totalMiB: total / 1024, availableMiB: available / 1024, targetMiB: targetMiB,
                machineMiB: machine.memoryMiB)
            guard target != targetMiB || balloon.targetVirtualMachineMemorySize != UInt64(target) << 20 else { return }
            targetMiB = target
            balloon.targetVirtualMachineMemorySize = UInt64(target) << 20
        }
    }

    /// A command run over `<name>-own`: not counted as use.
    func own(_ command: String, stdin: Data? = nil) async throws -> String {
        let out = try await Subprocess.run(
            [
                "/usr/bin/ssh", "-F", paths.sshConfig.path, "-T", "-o", "BatchMode=yes", machine.name + "-own",
                command
            ],
            cwd: "/", env: ProcessInfo.processInfo.environment, stdin: stdin, timeLimit: 20)
        guard out.status == 0 else { throw VMError(String(decoding: out.stderr, as: UTF8.self)) }
        return String(decoding: out.stdout, as: UTF8.self)
    }

    // MARK: configuration

    private func configuration() throws -> VZVirtualMachineConfiguration {
        try Self.configuration(machine, folder: folder, shares: shares)
    }

    // MARK: its screen

    /// The machine's screen as a view in its window, not shown: what reads and drives it from the Mac's side (`Screen`).
    private func screen() -> VZVirtualMachineView? {
        if window == nil {
            let view = VZVirtualMachineView()
            view.capturesSystemKeys = true
            view.automaticallyReconfiguresDisplay = false
            let screenWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: MacGuest.display.width / 2, height: MacGuest.display.height / 2),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            screenWindow.title = machine.name
            screenWindow.contentView = view
            screenWindow.contentAspectRatio = NSSize(width: MacGuest.display.width, height: MacGuest.display.height)
            screenWindow.isReleasedWhenClosed = false
            screenWindow.delegate = self
            screenWindow.center()
            window = screenWindow
            if machine.kind == .macos { PasswordButton.add(to: screenWindow, machine: machine.name, folder: folder) }
        }
        let view = window?.contentView as? VZVirtualMachineView
        if view?.virtualMachine !== vm { view?.virtualMachine = vm }
        return view
    }

    /// Its screen in a window of its own: full speed, the pointer and keys go to it. Closing it only hides it.
    private func show() {
        _ = screen()
        // In the Dock and ⌘Tab while it's shown, like any window one works in; out of them again once it's closed.
        NSApp.applicationIconImage = NSImage(named: NSImage.computerName)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)   // keys go to the machine at once, without a click into it first
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {   // AppKit asks on the main thread
            sender.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }
}

// MARK: sleeping and stopping

extension Runtime {
    /// SIGTERM (an install, a logout): saved, then gone. One still booting is let finish first: ending now would cut its
    /// power (a macOS first boot writes its account then).
    func leave() {   // internal: the tests drive it
        guard state != .starting else { return ready.append { [weak self] _ in self?.leave() } }
        sleep { [weak self] e in   // not saved: shut down as the guest would, not a power cut
            guard let self else { exit(0) }
            guard e != nil else { return exitProcess() }
            stop { self.exitProcess() }
        }
    }

    private func sleep(_ done: @escaping (String?) -> Void) {
        if saving { return saveDone.append(done) }
        guard let vm, state == .running || state == .paused else { return done(nil) }
        #if !arch(arm64)
            return done("Sleep needs a Mac with Apple silicon: an Intel Mac can't save a machine's state.")
        #else
            saving = true
            // Whatever came meanwhile is woken first (so a kelp-vm about to end for the sleep stays), then told.
            let end = { (error: String?) in
                self.saving = false
                if error != nil { self.saveFailed = self.now() }
                let waiting = self.saveDone, wanted = self.afterSave
                self.saveDone = []
                self.afterSave = []
                if !wanted.isEmpty { self.wake { e in wanted.forEach { $0(e) } } }
                waiting.forEach { $0(error) }
                done(error)
            }
            let tmp = saved.appendingPathExtension("part")
            let save = {
                vm.saveMachineStateTo(url: tmp) { error in
                    MainActor.assumeIsolated {
                        if let error {
                            log("save failed: \(error.localizedDescription)")
                            self.state = .paused
                            return end(error.localizedDescription)
                        }
                        guard rename(tmp.path, self.saved.path) == 0 else {
                            self.state = .paused
                            return end(String(cString: strerror(errno)))
                        }
                        vm.stop { _ in
                            MainActor.assumeIsolated {
                                self.vm = nil
                                self.state = .sleeping
                                log("asleep")
                                end(nil)
                            }
                        }
                    }
                }
            }
            if state == .paused { return save() }
            vm.pause { result in
                MainActor.assumeIsolated {
                    if let error = result.failure { return end(error.localizedDescription) }
                    save()
                }
            }
        #endif
    }

    /// Shuts the guest down (30 s, then off), and forgets a saved state: the next start boots.
    private func stop(_ done: @escaping () -> Void) {
        if saving { return saveDone.append { [weak self] _ in self?.stop(done) } }   // resumed under the save, it would fail it
        FileManager.default.removeIfAny(saved)
        guard let vm else {
            state = .off
            return done()
        }
        stopped.append(done)
        let request = {
            do { try vm.requestStop() } catch { vm.stop { _ in MainActor.assumeIsolated { self.down() } } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                MainActor.assumeIsolated {
                    if self.vm === vm { vm.stop { _ in MainActor.assumeIsolated { self.down() } } }
                }
            }
        }
        if vm.state == .paused { vm.resume { _ in MainActor.assumeIsolated { request() } } } else { request() }
    }
}

struct VMError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

extension Runtime {
    /// The command that sets the guest's clock to now.
    private func setClock() -> String {
        guard machine.kind == .macos else { return "sudo date -s @\(Int(Date().timeIntervalSince1970)) >/dev/null" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMddHHmmyyyy.ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "sudo date -u \(formatter.string(from: Date())) >/dev/null"
    }
}
