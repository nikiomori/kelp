import CryptoKit
import Foundation
import os
import Core

/// Kelp's virtual machines (Core/VMs.swift): makes them, starts each one's `kelp-vm` and asks it how it is. Keeps nothing in
/// memory: a machine is its folder (a `creating` file while it's being made, `failed` after that went wrong). A machine's
/// own process outlives kelpd (started through `sh … &`, so it isn't kelpd's child): a restart or an upgrade here leaves
/// what runs inside alone.
struct VMService: Sendable {
    let root: URL
    /// kelp-vm, beside kelpd.
    let helper: String

    init(home: URL, helper: String) { root = home.appendingPathComponent("vms"); self.helper = helper }

    func folder(_ name: String) -> URL { root.appendingPathComponent(name) }
    func file(_ name: String, _ file: String) -> URL { folder(name).appendingPathComponent(file) }
    var images: URL { root.appendingPathComponent(".images") }

    func machine(_ name: String) throws -> VMMachine {
        guard VMs.isName(name), let d = FileManager.default.contents(atPath: file(name, "machine.json").path) else {
            throw RPCError.invalidParams("No machine called \(name). `kelp vm list` shows them; `kelp vm create \(name)` makes one.")
        }
        return try JSONDecoder().decode(VMMachine.self, from: d)
    }

    /// `sessions`: who runs something in each busy one, read from inside (an SSH run each).
    func list(sessions: Bool = false) -> [VMInfo] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") } } catch { return [] }
        return names.sorted().compactMap { n in
            var v: VMInfo
            do { v = info(try machine(n)) } catch { return nil }
            if sessions, v.state == .running, (v.connections ?? 0) > 0 {
                v.sessions = Array(Set(detail(n)?.runs.compactMap(\.session) ?? [])).sorted()
            }
            return v
        }
    }

    /// What runs in it, read over its own connection, which neither wakes it nor counts as use; nil unless it runs.
    func detail(_ name: String) -> VMDetail? {
        // Android and iOS: none (no SSH inside them).
        let device = ["avd", "udid"].contains { FileManager.default.fileExists(atPath: file(name, $0).path) }
        guard status(name)?.state == .running, !device else { return nil }
        let out: Subprocess.Output
        do {
            out = try Subprocess.run(["/usr/bin/ssh", "-F", file(name, "ssh_config").path, "-T", "-o", "BatchMode=yes", name + "-own", "sh"],
                                     cwd: "/", env: ProcessInfo.processInfo.environment, stdin: Data(VMs.detailScript.utf8), timeLimit: 10)
        } catch { Log.vm.info("reading \(name): \(error)"); return nil }
        guard out.status == 0 else { return nil }
        var d = VMs.parseDetail(String(decoding: out.stdout, as: UTF8.self))
        if let json = FileManager.default.contents(atPath: file(name, "shares.json").path) {
            do { d.folders = try JSONDecoder().decode([Int: String].self, from: json).values.sorted() } catch { Log.vm.error("\(name)'s shares: \(error)") }
        }
        return d
    }

    private func info(_ m: VMMachine) -> VMInfo {
        if let failed = failure(m.name) { return VMInfo(machine: m, state: .error, detail: failed) }
        if let step = making(m.name) { return VMInfo(machine: m, state: .creating, detail: step) }
        var st = stat()
        let disk = stat(file(m.name, "disk.img").path, &st) == 0 ? (Int(st.st_blocks) * 512) >> 20 : nil
        guard let r = status(m.name) else {
            let asleep = FileManager.default.fileExists(atPath: file(m.name, "state.vzsave").path)
            return VMInfo(machine: m, state: asleep ? .sleeping : .off, diskMiB: disk)
        }
        return VMInfo(machine: m, state: r.state, detail: r.error, connections: r.connections, memoryMiB: r.memoryMiB, diskMiB: disk)
    }

    func text(_ name: String, _ f: String) -> String? {
        FileManager.default.contents(atPath: file(name, f).path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Why it wasn't made: what failed, or that making it stopped midway (kelpd ended: its `creating` went stale).
    func failure(_ name: String) -> String? {
        if let failed = text(name, "failed") { return failed }
        guard text(name, "creating") != nil, making(name) == nil else { return nil }
        return String(localized: "Making it stopped midway (Kelp restarted). Delete it and make it again.")
    }

    /// What making it is at, unless that stopped (kelpd ended midway: nothing updated it for 45 minutes, longer than a
    /// macOS first boot, its longest quiet step).
    func making(_ name: String) -> String? {
        var st = stat()
        guard let step = text(name, "creating"), stat(file(name, "creating").path, &st) == 0 else { return nil }
        return Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) < 2700 ? step : nil
    }

    // MARK: running

    func control(_ name: String, _ action: VMControl.Action) throws -> VMInfo {
        let m = [.stop, .delete].contains(action) ? try machine(name) : try ready(name)
        switch action {
        case .delete:
            quit(name)
            if let udid = text(name, "udid") {   // an iOS machine's simulator lives in Xcode's device set
                do { try run(["/usr/bin/xcrun", "simctl", "delete", udid.trimmingCharacters(in: .whitespacesAndNewlines)]) }
                catch { Log.vm.error("deleting \(name)'s simulator: \(error)") }
            }
            try FileManager.default.removeItem(at: folder(name))
            Keychain.delete("vm." + name)
            var gone = VMInfo(machine: m, state: .off)
            gone.detail = String(localized: "Deleted")
            return gone
        case .start:
            try admit(m)
            try startHelper(m)
            try check(ask(name, .init(op: .start), wait: 620))
        case .show:
            guard m.os != "linux" else { throw RPCError.invalidParams("\(name) has no screen: it's Linux. kelp vm run \(name) opens its shell.") }
            try admit(m)
            try startHelper(m)
            try check(ask(name, .init(op: .show), wait: 180))
        case .sleep, .stop:
            if status(name) != nil { try check(ask(name, .init(op: action == .sleep ? .sleep : .stop), wait: 60)) }
            else if action == .stop { remove(file(name, "state.vzsave")) }
        }
        return info(m)
    }

    /// The machine's ssh, with `cwd`'s project folder shared at its own path (the git repository's top, else `cwd`);
    /// no `cwd`: its home folder, nothing shared.
    func connect(_ name: String, cwd: String?) throws -> VMConnection {
        let m = try ready(name)
        if m.os == "ios" {   // simctl for its simulator, and its runner's port: booted first
            try admit(m)
            try startHelper(m)
            let r = try ask(name, .init(op: .start), wait: 620)
            try check(r)
            guard let udid = r.serial, let port = r.port else { throw RPCError.internalError("\(name)'s simulator isn't up") }
            return VMConnection(ssh: ["/usr/bin/xcrun", "simctl"], prefix: "", device: udid, port: port)
        }
        if m.os == "android" {   // adb to its emulator, booted or woken first
            try admit(m)
            try startHelper(m)
            let r = try ask(name, .init(op: .start), wait: 620)
            try check(r)
            guard let adb = AndroidSDK.adb, let serial = r.serial else { throw RPCError.internalError("\(name)'s emulator has no adb serial") }
            return VMConnection(ssh: [adb, "-s", serial], prefix: "")
        }
        let ssh = ["/usr/bin/ssh", "-F", file(name, "ssh_config").path, name]
        guard let cwd else {
            try admit(m)
            try startHelper(m)
            return VMConnection(ssh: ssh, prefix: "cd || exit 1; ")
        }
        let project = projectFolder(cwd)
        guard VMs.mayShare(project) else {
            throw RPCError.invalidParams("\(project) can't be shared with a machine: only folders inside your home folder "
                + "(not it, ~/.ssh or ~/Library). Pass --cwd <project folder>.")
        }
        try admit(m)
        try startHelper(m)
        let shared = try ask(name, .init(op: .share, path: project), wait: 5)
        try check(shared)
        guard let slot = shared.slot else { throw RPCError.internalError("\(name) didn't share \(project)") }
        return VMConnection(ssh: ssh, prefix: VMs.prefix(slot: slot, folder: project, cwd: cwd, os: m.os))
    }

    private func ready(_ name: String) throws -> VMMachine {
        let m = try machine(name)
        if let failed = failure(name) { throw RPCError.invalidParams("\(name) wasn't made: \(failed)") }
        if making(name) != nil { throw RPCError.invalidParams("\(name) is still being made: `kelp vm list` shows how far.") }
        return m
    }

    private func projectFolder(_ cwd: String) -> String {
        let env = ProcessInfo.processInfo.environment
        do {
            let top = try Subprocess.run(["/usr/bin/git", "-C", cwd, "rev-parse", "--show-toplevel"], cwd: "/", env: env, timeLimit: 10)
            if top.status == 0 { return String(decoding: top.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        } catch { Log.vm.info("git for \(cwd): \(error)") }
        return cwd
    }

    /// Room in the memory budget (a quarter of the Mac's) for `m` to wake: idle machines are put to sleep for it, else no.
    private func admit(_ m: VMMachine) throws {
        let up: Set<VMState> = [.running, .paused, .starting]
        if let me = status(m.name), up.contains(me.state) { return }
        let budget = Int(ProcessInfo.processInfo.physicalMemory >> 20) / 4
        var awake = list().filter { $0.machine.name != m.name && up.contains($0.state) }
        func used() -> Int { awake.reduce(m.memoryMiB) { $0 + ($1.memoryMiB ?? $1.machine.memoryMiB) } }
        let idle = awake.filter { $0.connections == 0 }.sorted { ($0.memoryMiB ?? 0) > ($1.memoryMiB ?? 0) }
        for other in idle where used() > budget {
            do { _ = try ask(other.machine.name, .init(op: .sleep), wait: 60) } catch { continue }
            awake.removeAll { $0.machine.name == other.machine.name }
        }
        guard used() <= budget else {
            let busy = awake.map { $0.machine.name }.joined(separator: ", ")
            throw RPCError.invalidParams("Not enough of the machines' memory budget (\(budget >> 10) GB) to wake \(m.name): "
                + "\(busy) are in use. Put one to sleep: kelp vm sleep <name>.")
        }
    }

    /// Starts the machine's `kelp-vm` unless it runs.
    func startHelper(_ m: VMMachine) throws {
        if status(m.name) != nil { return }
        let log = file(m.name, "helper.log").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw RPCError.internalError("This build of Kelp has no kelp-vm beside kelpd (\(helper)).")
        }
        let line = "\(VMs.shellQuoted(helper)) \(VMs.shellQuoted(folder(m.name).path)) >> \(VMs.shellQuoted(log)) 2>&1 < /dev/null &"
        _ = try Subprocess.run(["/bin/sh", "-c", line], cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 10)
        for _ in 0..<50 {
            if status(m.name) != nil { return }
            usleep(100_000)
        }
        let tail = text(m.name, "helper.log")?.split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
        try check(VMHelper.Reply(state: .error, connections: 0, error: "\(m.name)'s kelp-vm didn't start: \(tail)"))
    }

    /// How it is, from its kelp-vm; nil when that isn't running.
    func status(_ name: String) -> VMHelper.Reply? {
        do { return try ask(name, .init(op: .status), wait: 2) } catch { return nil }
    }

    /// One request to the machine's kelp-vm; `wait` seconds for its answer.
    func ask(_ name: String, _ r: VMHelper.Request, wait: TimeInterval) throws -> VMHelper.Reply {
        let fd = try Unix.connect(file(name, "ctl.sock").path)
        defer { close(fd) }
        guard Unix.writeAll(fd, try Wire.line(r)) else { throw RPCError.internalError("\(name)'s kelp-vm hung up") }
        var line = Data(), byte: UInt8 = 0
        let end = Date().addingTimeInterval(wait)
        while true {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, end.timeIntervalSinceNow) * 1000)
            guard left > 0, poll(&p, 1, left) > 0, read(fd, &byte, 1) == 1 else {
                throw RPCError.internalError("\(name) didn't answer in \(Int(wait)) s")
            }
            if byte == 0x0A { break }
            line.append(byte)
        }
        return try JSONDecoder().decode(VMHelper.Reply.self, from: line)
    }

    /// Its kelp-vm gone, the machine off at once: before its folder is (deleted, or made again).
    func quit(_ name: String) {
        guard status(name) != nil else { return }
        do { _ = try ask(name, .init(op: .quit), wait: 10) } catch { Log.vm.info("\(name) quit: \(error)") }   // it hangs up as it goes
        for _ in 0..<50 where status(name) != nil { usleep(100_000) }
    }

    func check(_ r: VMHelper.Reply) throws {
        guard let e = r.error else { return }
        guard e.contains("entitlement") else { throw RPCError.internalError(e) }
        // A debug build: `swift build` links kelp-vm anew, without the entitlement scripts/bundle.sh signs it with.
        throw RPCError.internalError("kelp-vm isn't signed for virtualization: "
            + "codesign --force --sign - --entitlements Resources/KelpVM.entitlements \(helper)")
    }

    func remove(_ u: URL) {
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        Log.vm.attempt("removing \(u.path)") { try FileManager.default.removeItem(at: u) }
    }

    // MARK: making one

    func create(_ r: VMCreate) throws -> VMInfo {
        #if arch(x86_64)
        throw RPCError.invalidParams("Machines need a Mac with Apple silicon: their images are for ARM.")
        #endif
        guard VMs.isName(r.name) else {
            throw RPCError.invalidParams("A machine's name: up to 20 lowercase letters, digits and dashes, starting with a letter.")
        }
        let id = r.image ?? "debian-13"
        guard let image = VMImage.named(id) else {
            throw RPCError.invalidParams("No image \(id). There are: \(VMImage.all.map(\.id).joined(separator: ", ")).")
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount, gib = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        let mac = image.os == "macos"
        let cpus = r.cpus ?? (mac ? 4 : 2), memory = r.memory ?? (mac ? 6 : 2), disk = r.disk ?? (mac ? 64 : ["android", "ios"].contains(image.os) ? 8 : 32)
        guard (1...cores).contains(cpus), (1...max(1, gib / 2)).contains(memory), (8...2048).contains(disk) else {
            throw RPCError.invalidParams("--cpus 1–\(cores), --memory 1–\(max(1, gib / 2)) GB, --disk 8–2048 GB.")
        }
        let m = VMMachine(name: r.name, os: image.os, image: image.id, cpus: cpus, memoryMiB: memory << 10, diskGiB: disk,
                          user: VMs.user(NSUserName()), rosetta: image.os == "linux")
        let f = folder(m.name)
        if failure(m.name) != nil { quit(m.name); try FileManager.default.removeItem(at: f) }   // an earlier try's remains
        try Paths.ensure(root)
        do { try FileManager.default.createDirectory(at: f, withIntermediateDirectories: false) } catch CocoaError.fileWriteFileExists {
            throw RPCError.invalidParams("There's already a machine called \(m.name).")
        }
        chmod(f.path, 0o700)
        step(m, "Getting \(image.title)")
        try JSONEncoder().encode(m).write(to: file(m.name, "machine.json"))
        Task.detached {
            switch image.os {
            case "macos": await self.makeMac(m)
            case "android": await self.makeAndroid(m)
            case "ios": await self.makeIOS(m)
            default: await self.make(m, image)
            }
        }
        return info(m)
    }

    func step(_ m: VMMachine, _ text: String) {
        Log.vm.attempt("noting \(m.name)'s progress") { try Data(text.utf8).write(to: file(m.name, "creating"), options: .atomic) }
    }

    private func make(_ m: VMMachine, _ image: VMImage) async {
        await making(m) {
            let raw = try await self.image(image) { step(m, $0) }
            step(m, "Making its disk")
            try await blocking { try makeFolder(m, from: raw) }
            step(m, "Starting for the first time")
            try await blocking { try startHelper(m); try check(ask(m.name, .init(op: .start), wait: 620)) }
        }
    }

    /// Slow work that waits on a program or a socket: on a thread of its own, never one of Swift's few pool threads.
    func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in Thread.detachNewThread { c.resume(with: Result { try work() }) } }
    }

    /// Runs the steps of making `m`; its `creating` file goes when they end, and why they failed stays in `failed`.
    func making(_ m: VMMachine, _ steps: () async throws -> Void) async {
        do { try await steps() } catch {
            Log.vm.error("making \(m.name): \(error)")
            quit(m.name)   // a machine half made holds memory and a disk for nothing
            let why = (error as? RPCError)?.message ?? error.localizedDescription
            Log.vm.attempt("noting why \(m.name) failed") { try Data(why.utf8).write(to: file(m.name, "failed")) }
        }
        remove(file(m.name, "creating"))
    }

    /// The image's raw disk, downloaded and checked the first time.
    private func image(_ image: VMImage, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let raw = images.appendingPathComponent(image.id + ".raw")
        if FileManager.default.fileExists(atPath: raw.path) { return raw }
        try Paths.ensure(images)
        guard let url = URL(string: image.url), let sumsURL = URL(string: image.sums) else { throw RPCError.internalError("bad image address") }
        let (sums, _) = try await URLSession.shared.data(from: sumsURL)
        let name = url.lastPathComponent
        let line = String(decoding: sums, as: UTF8.self).split(separator: "\n").first { $0.hasSuffix("  " + name) }
        guard let want = line?.split(separator: " ").first else { throw RPCError.internalError("\(name) isn't in \(image.sums)") }
        let watcher = DownloadProgress { progress("Downloading \(image.title): \(Int($0 * 100))%") }
        let (tmp, _) = try await URLSession.shared.download(from: url, delegate: watcher)
        defer { remove(tmp) }
        progress("Checking \(image.title)")
        guard try await blocking({ try Self.sha512(tmp) }) == want else {
            throw RPCError.internalError("\(name) doesn't match its published checksum: not used")
        }
        progress("Unpacking \(image.title)")
        let dir = images.appendingPathComponent(".unpack-\(image.id)-\(UUID().uuidString.prefix(8))")   // another make may unpack too
        try Paths.ensure(dir)
        defer { remove(dir) }
        let out = try await Subprocess.run(["/usr/bin/tar", "-xf", tmp.path, "-C", dir.path, image.member], cwd: "/", env: [:], timeLimit: 600)
        guard out.status == 0 else { throw RPCError.internalError("tar: " + String(decoding: out.stderr, as: UTF8.self)) }
        if !FileManager.default.fileExists(atPath: raw.path) {   // else another make unpacked it first
            try FileManager.default.moveItem(at: dir.appendingPathComponent(image.member), to: raw)
        }
        return raw
    }

    static func sha512(_ file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { h.closeFile() }
        var sha = SHA512()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The machine's folder: its disk (an APFS clone of the image, grown), key, cloud-init seed, ssh_config.
    private func makeFolder(_ m: VMMachine, from raw: URL) throws {
        let disk = file(m.name, "disk.img")
        try FileManager.default.copyItem(at: raw, to: disk)   // clonefile on APFS: no space taken until it differs
        guard truncate(disk.path, off_t(m.diskGiB) << 30) == 0 else {
            throw RPCError.internalError("can't size the disk: \(String(cString: strerror(errno)))")
        }
        let key = file(m.name, "id_ed25519")
        try run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "kelp-vm-" + m.name, "-f", key.path])
        let seed = file(m.name, ".seed")
        try Paths.ensure(seed)
        defer { remove(seed) }
        let pub = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        try VMs.userData(m, publicKey: pub, timeZone: TimeZone.current.identifier)
            .write(to: seed.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try "instance-id: \(UUID().uuidString)\nlocal-hostname: \(m.name)\n"
            .write(to: seed.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        try run(["/usr/bin/hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
                 "-o", file(m.name, "seed.iso").path, seed.path])
        try VMs.sshConfig(m, folder: folder(m.name)).write(to: file(m.name, "ssh_config"), atomically: true, encoding: .utf8)
    }

    /// A program's output; its error when it fails.
    @discardableResult
    func run(_ argv: [String], limit: TimeInterval = 60) throws -> String {
        let out = try Subprocess.run(argv, cwd: "/", env: [:], timeLimit: limit)
        guard out.status == 0 else {
            throw RPCError.internalError((argv[0] as NSString).lastPathComponent + ": " + String(decoding: out.stderr, as: UTF8.self))
        }
        return String(decoding: out.stdout, as: UTF8.self)
    }
}

/// A download's progress, as it goes (URLSession's async download reports only the end).
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    private let watching = OSAllocatedUnfairLock<(NSKeyValueObservation?, percent: Int)>(initialState: (nil, -1))
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let o = task.progress.observe(\.fractionCompleted) { [weak self, report] p, _ in
            let percent = Int(p.fractionCompleted * 100)   // a percent at a time, not every few kilobytes
            guard self?.watching.withLock({ w in defer { w.percent = percent }; return w.percent != percent }) == true else { return }
            report(p.fractionCompleted)
        }
        watching.withLock { $0.0 = o }
    }
}

extension VMList: Handled {
    func handle(_ vms: VMService) throws -> [VMInfo] { vms.list(sessions: true) }
}

extension VMDetailRead: Handled {
    func handle(_ vms: VMService) throws -> VMDetail? { vms.detail(name) }
}

extension VMCreate: Handled {
    /// It downloads gigabytes and takes memory from every chat's budget: the user's to decide.
    var notForAgents: String? { "Making a machine is the user's: they run kelp vm create in a terminal of theirs." }
    func handle(_ vms: VMService) throws -> VMInfo { try vms.create(self) }
}

extension VMControl: Handled {
    /// Other chats run commands in it: shutting it down or deleting it is the user's (sleeping is fine: the next command wakes it).
    var notForAgents: String? {
        [.stop, .delete].contains(action) ? "Shutting a machine down or deleting it is the user's: other chats may be running in it." : nil
    }
    func handle(_ vms: VMService) throws -> VMInfo { try vms.control(name, action) }
}

extension VMConnect: Handled {
    func handle(_ vms: VMService) throws -> VMConnection { try vms.connect(name, cwd: cwd) }
}

extension Methods {
    static let vmMethods: [any Handled.Type] = [VMList.self, VMCreate.self, VMControl.self, VMConnect.self, VMDetailRead.self]
}
