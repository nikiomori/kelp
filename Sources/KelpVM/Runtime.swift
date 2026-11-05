import Foundation
import Virtualization
import Core

/// One line to stdout, which kelpd sends to the machine's helper.log.
func log(_ s: String) { print("\(Date().formatted(.iso8601)) \(s)") }

/// The machine and its connections. Everything here runs on the main queue: the VM's (VZVirtualMachine's default) and
/// the sockets' handlers alike.
@MainActor
final class Runtime: NSObject, VZVirtualMachineDelegate {
    let folder: URL, machine: VMMachine
    private var vm: VZVirtualMachine?
    private(set) var state: VMState
    /// The folder in each share slot (`VMs.shareSlots`, also in shares.json), and when each was last asked for.
    private var shares: [Int: String]
    private var shareUse: [Int: Date] = [:]
    /// Agents' and people's SSH connections open now; none for a while, and it pauses, then sleeps.
    private var connections = 0
    private var lastUse = Date()
    private var ready: [(String?) -> Void] = [], stopped: [() -> Void] = []
    private var targetMiB: Int
    private var sockets: [Int: VZVirtioSocketConnection] = [:]
    private var nextSocket = 0
    private var ticks = 0
    private var listeners: [DispatchSourceRead] = [], signals: [DispatchSourceSignal] = []

    static let pauseAfter: TimeInterval = 120, sleepAfter: TimeInterval = 600
    private var saved: URL { folder.appendingPathComponent("state.vzsave") }
    private func file(_ n: String) -> URL { folder.appendingPathComponent(n) }

    init(folder: URL) throws {
        self.folder = folder
        machine = try JSONDecoder().decode(VMMachine.self, from: Data(contentsOf: folder.appendingPathComponent("machine.json")))
        shares = (try? JSONDecoder().decode([Int: String].self, from: Data(contentsOf: folder.appendingPathComponent("shares.json")))) ?? [:]
        state = FileManager.default.fileExists(atPath: folder.appendingPathComponent("state.vzsave").path) ? .sleeping : .off
        targetMiB = machine.memoryMiB
        super.init()
    }

    // MARK: sockets

    func listen() {
        listen("ssh.sock") { [weak self] fd in self?.connect(fd, counted: true) }
        listen("own.sock") { [weak self] fd in self?.connect(fd, counted: false) }
        listen("ctl.sock") { [weak self] fd in self?.control(fd) }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }   // main run loop
        RunLoop.main.add(timer, forMode: .common)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            // On the main queue: save it (what runs inside goes on at the next wake), then go.
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sleep { _ in exit(0) } } }
            s.resume()
            signals.append(s)
        }
        log("ready: \(machine.name), \(state.rawValue)")
    }

    private func listen(_ name: String, _ accepted: @escaping @MainActor (Int32) -> Void) {
        let fd: Int32
        do { fd = try Unix.listen(file(name).path) } catch { log("can't listen on \(name): \(error)"); exit(1) }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            Unix.noSigPipe(c)
            MainActor.assumeIsolated { accepted(c) }   // a read source on the main queue
        }
        src.resume()
        listeners.append(src)
    }

    /// An SSH connection: wakes the machine, then joins the client to the guest's sshd on vsock port 22.
    private func connect(_ client: Int32, counted: Bool) {
        if counted { connections += 1; lastUse = Date() }
        let join: (String?) -> Void = { [self] error in
            guard error == nil, let dev = vm?.socketDevices.first as? VZVirtioSocketDevice else { return finish(client, counted) }
            dev.connect(toPort: 22) { result in
                MainActor.assumeIsolated {   // VZ answers on the VM's queue, the main one
                    switch result {
                    case .success(let conn): self.pump(client, conn, counted)
                    case .failure(let e): log("vsock: \(e.localizedDescription)"); self.finish(client, counted)
                    }
                }
            }
        }
        // Kelp's own reads come while it starts (the clock, before it counts as ready): they don't wait for it, nor wake it.
        if counted { wake(join) } else { join(vm == nil ? "asleep" : nil) }
    }

    private func pump(_ client: Int32, _ conn: VZVirtioSocketConnection, _ counted: Bool) {
        nextSocket += 1
        let id = nextSocket, guest = conn.fileDescriptor
        sockets[id] = conn
        let both = DispatchGroup()
        for (from, to) in [(client, guest), (guest, client)] {
            both.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(from, &buf, buf.count)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 || !Unix.writeAll(to, Data(buf[0..<n])) { break }
                }
                shutdown(to, SHUT_WR)
                both.leave()
            }
        }
        both.notify(queue: .main) {
            MainActor.assumeIsolated {   // notify on the main queue
                self.sockets.removeValue(forKey: id)?.close()
                self.finish(client, counted)
            }
        }
    }

    private func finish(_ client: Int32, _ counted: Bool) {
        close(client)
        if counted { connections -= 1; lastUse = Date() }
    }

    /// kelpd's requests: one JSON line in, one out.
    private func control(_ fd: Int32) {
        Thread.detachNewThread {
            var line = Data(), byte: UInt8 = 0
            while line.count < 65536, read(fd, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
            let request = try? JSONDecoder().decode(VMHelper.Request.self, from: line)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let request else { return self.reply(fd, "can't read the request") }
                    self.handle(request) { error, slot in self.reply(fd, error, slot: slot) }
                }
            }
        }
    }

    private func handle(_ r: VMHelper.Request, _ done: @escaping (String?, Int?) -> Void) {
        switch r.op {
        case .status: done(nil, nil)
        case .start: lastUse = Date(); wake { done($0, nil) }
        case .sleep: sleep { done($0, nil) }
        case .stop: stop { done(nil, nil) }
        case .share:
            guard let path = r.path else { return done("share: a path", nil) }
            let slot = shares.first { $0.value == path }?.key
                ?? (0..<VMs.shareSlots).first { shares[$0] == nil }
                ?? (0..<VMs.shareSlots).min { shareUse[$0] ?? .distantPast < shareUse[$1] ?? .distantPast } ?? 0
            shareUse[slot] = Date()
            guard shares[slot] != path else { return done(nil, slot) }
            shares[slot] = path
            do { try JSONEncoder().encode(shares).write(to: file("shares.json")) } catch { return done("\(error)", nil) }
            if let dev = vm?.directorySharingDevices.first(where: { ($0 as? VZVirtioFileSystemDevice)?.tag == "kelp\(slot)" }) as? VZVirtioFileSystemDevice {
                dev.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: path), readOnly: false))
            }
            done(nil, slot)
        }
    }

    private func reply(_ fd: Int32, _ error: String?, slot: Int? = nil) {
        let r = VMHelper.Reply(state: state, connections: connections, memoryMiB: vm == nil ? nil : targetMiB, error: error, slot: slot)
        if let d = try? Wire.line(r) { Unix.writeAll(fd, d) }
        close(fd)
    }

    // MARK: the machine

    private func wake(_ done: @escaping (String?) -> Void) {
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
        guard FileManager.default.fileExists(atPath: saved.path) else {
            return vm.start { r in MainActor.assumeIsolated { self.awaitSSH(restored: false, error: r.failure) } }
        }
        vm.restoreMachineStateFrom(url: saved) { error in
            MainActor.assumeIsolated {
                try? FileManager.default.removeItem(at: self.saved)   // a saved state restores once
                if let error {   // from an older macOS, or damaged: boot instead
                    log("restore failed, booting: \(error.localizedDescription)")
                    return vm.start { r in MainActor.assumeIsolated { self.awaitSSH(restored: false, error: r.failure) } }
                }
                // The guest's balloon comes back inflated while the Mac maps all of its memory again: let it go, so that
                // inflating it anew (`adjustMemory`) hands those pages back.
                let balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
                balloon?.targetVirtualMachineMemorySize = UInt64(self.machine.memoryMiB) << 20
                vm.resume { r in MainActor.assumeIsolated { self.awaitSSH(restored: true, error: r.failure) } }
            }
        }
    }

    /// Ready once sshd answers on vsock 22 with its banner (systemd's sshd-vsock socket listens before sshd can answer).
    private func awaitSSH(restored: Bool, error: Error?, since: Date = Date()) {
        if let error { return started(error) }
        let firstBoot = !FileManager.default.fileExists(atPath: file("booted").path)
        guard Date().timeIntervalSince(since) < (firstBoot ? 600 : 120) else { return started(VMError("sshd didn't answer")) }
        guard let dev = vm?.socketDevices.first as? VZVirtioSocketDevice else { return started(VMError("no vsock device")) }
        dev.connect(toPort: 22) { result in
            MainActor.assumeIsolated {
                guard case .success(let conn) = result else { return self.retry(restored, since) }
                let fd = conn.fileDescriptor
                self.nextSocket += 1
                let id = self.nextSocket
                self.sockets[id] = conn
                Thread.detachNewThread {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0), buf = [UInt8](repeating: 0, count: 4)
                    let ok = poll(&pfd, 1, 3000) > 0 && read(fd, &buf, 4) == 4 && buf == Array("SSH-".utf8)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.sockets.removeValue(forKey: id)?.close()
                            guard ok else { return self.retry(restored, since) }
                            FileManager.default.createFile(atPath: self.file("booted").path, contents: nil)
                            guard restored else { return self.started(nil) }
                            // A restored guest's clock says when it was saved: right before the first command runs (make
                            // and friends compare times).
                            Task { _ = try? await self.own("sudo date -s @\(Int(Date().timeIntervalSince1970)) >/dev/null"); self.started(nil) }
                        }
                    }
                }
            }
        }
    }

    private func retry(_ restored: Bool, _ since: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self.awaitSSH(restored: restored, error: nil, since: since) } }
    }

    private func started(_ error: Error?) {
        if let error { log("start failed: \(error.localizedDescription)") }
        state = error == nil ? .running : .error
        lastUse = Date()
        let waiting = ready; ready = []
        waiting.forEach { $0(error?.localizedDescription) }
        if error == nil { adjustMemory() }
    }

    private func sleep(_ done: @escaping (String?) -> Void) {
        guard let vm, state == .running || state == .paused else { return done(nil) }
        let tmp = file("state.vzsave.part")
        let save = {
            vm.saveMachineStateTo(url: tmp) { error in
                MainActor.assumeIsolated {
                    if let error { log("save failed: \(error.localizedDescription)"); self.state = .paused; return done(error.localizedDescription) }
                    guard rename(tmp.path, self.saved.path) == 0 else { return done(String(cString: strerror(errno))) }
                    vm.stop { _ in MainActor.assumeIsolated { self.vm = nil; self.state = .sleeping; log("asleep"); done(nil) } }
                }
            }
        }
        if state == .paused { return save() }
        vm.pause { r in MainActor.assumeIsolated { if let e = r.failure { return done(e.localizedDescription) }; save() } }
    }

    /// Shuts the guest down (30 s, then off), and forgets a saved state: the next start boots.
    private func stop(_ done: @escaping () -> Void) {
        try? FileManager.default.removeItem(at: saved)
        guard let vm else { state = .off; return done() }
        stopped.append(done)
        let request = {
            do { try vm.requestStop() } catch { vm.stop { _ in MainActor.assumeIsolated { self.down() } } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                MainActor.assumeIsolated { if self.vm === vm { vm.stop { _ in MainActor.assumeIsolated { self.down() } } } }
            }
        }
        if vm.state == .paused { vm.resume { _ in MainActor.assumeIsolated { request() } } } else { request() }
    }

    private func down() {
        vm = nil; state = .off
        let waiting = stopped; stopped = []
        waiting.forEach { $0() }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { log("the guest shut down"); down() }   // the VM's queue, the main one
    }
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { log("stopped: \(error.localizedDescription)"); down(); state = .error }
    }

    /// Every 5 s: no connection for `pauseAfter`, and it pauses; for `sleepAfter`, it goes to disk. While it runs, its
    /// memory follows what the guest uses every 15 s.
    private func tick() {
        ticks += 1
        let idle = Date().timeIntervalSince(lastUse)
        if state == .running, connections == 0, idle > Self.pauseAfter {
            vm?.pause { r in MainActor.assumeIsolated { if r.failure == nil, self.state == .running { self.state = .paused; log("paused") } } }
        } else if state == .paused, connections == 0, idle > Self.sleepAfter {
            sleep { _ in }
        } else if state == .running, ticks % 3 == 0 {
            adjustMemory()
        }
    }

    // MARK: inside

    /// The balloon gives the Mac back what the guest doesn't use (`VMs.memoryTarget`). A restore maps all of `memoryMiB`;
    /// this takes it back.
    private func adjustMemory() {
        Task {
            guard let text = try? await own("cat /proc/meminfo") else { return }
            func kb(_ key: String) -> Int? {
                text.split(separator: "\n").first { $0.hasPrefix(key + ":") }?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
            }
            guard let total = kb("MemTotal"), let available = kb("MemAvailable"), state == .running,
                  let balloon = vm?.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else { return }
            let target = VMs.memoryTarget(totalMiB: total / 1024, availableMiB: available / 1024, targetMiB: targetMiB, machineMiB: machine.memoryMiB)
            guard target != targetMiB || balloon.targetVirtualMachineMemorySize != UInt64(target) << 20 else { return }
            targetMiB = target
            balloon.targetVirtualMachineMemorySize = UInt64(target) << 20
        }
    }

    /// A command run over `<name>-own`: not counted as use.
    private func own(_ command: String) async throws -> String {
        let out = try await Subprocess.run(["/usr/bin/ssh", "-F", file("ssh_config").path, "-T", "-o", "BatchMode=yes", machine.name + "-own", command],
                                           cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 20)
        guard out.status == 0 else { throw VMError(String(decoding: out.stderr, as: UTF8.self)) }
        return String(decoding: out.stdout, as: UTF8.self)
    }

    // MARK: configuration

    private func configuration() throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        let boot = VZEFIBootLoader()
        let vars = file("efi.vars")
        boot.variableStore = FileManager.default.fileExists(atPath: vars.path)
            ? VZEFIVariableStore(url: vars) : try VZEFIVariableStore(creatingVariableStoreAt: vars)
        c.bootLoader = boot
        let platform = VZGenericPlatformConfiguration()
        if let d = try? Data(contentsOf: file("machine.id")), let id = VZGenericMachineIdentifier(dataRepresentation: d) { platform.machineIdentifier = id }
        else { try platform.machineIdentifier.dataRepresentation.write(to: file("machine.id")) }
        c.platform = platform
        c.cpuCount = machine.cpus
        c.memorySize = UInt64(machine.memoryMiB) << 20
        c.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: file("disk.img"), readOnly: false,
                                                                                                 cachingMode: .automatic, synchronizationMode: .fsync)),
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: file("seed.iso"), readOnly: true))
        ]
        if machine.network {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            if let s = try? String(contentsOf: file("mac"), encoding: .utf8), let mac = VZMACAddress(string: s) { net.macAddress = mac }
            else { try net.macAddress.string.write(to: file("mac"), atomically: true, encoding: .utf8) }
            c.networkDevices = [net]
        }
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = try VZFileSerialPortAttachment(url: file("console.log"), append: false)
        c.serialPorts = [console]
        c.directorySharingDevices = (0..<VMs.shareSlots).map { slot in
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "kelp\(slot)")
            fs.share = shares[slot].flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                .map { VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: $0), readOnly: false)) }
            return fs
        }
        if machine.rosetta, VZLinuxRosettaDirectoryShare.availability == .installed {
            let r = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            r.share = try VZLinuxRosettaDirectoryShare()
            c.directorySharingDevices.append(r)
        }
        try c.validate()
        return c
    }
}

struct VMError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e }; return nil }
}
