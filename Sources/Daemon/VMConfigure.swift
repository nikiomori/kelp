import Foundation
import Core

/// A machine's files: one of the user's it's made from, its exchange folder; and its size, changed while it's shut down.
extension VMService {
    /// The file a machine is made from, before anything is made: what it is, as far as its first bytes tell.
    static func check(_ file: URL, for image: VMImage) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { throw RPCError.invalidParams("No file \(file.path).") }
        switch image.os {
        case "macos":
            guard file.pathExtension.lowercased() == "ipsw" else { throw RPCError.invalidParams("A macOS machine is made from a restore image (.ipsw).") }
        case "linux":
            let h = try FileHandle(forReadingFrom: file)
            defer { h.closeFile() }
            let head = try h.read(upToCount: 0x8006) ?? Data()
            if head.prefix(4) == Data([0x51, 0x46, 0x49, 0xFB]) {
                throw RPCError.invalidParams("That's a qcow2 image: Kelp runs raw disks. qemu-img convert -O raw \(file.lastPathComponent) disk.raw makes one.")
            }
            if head.count >= 0x8006, head[0x8001..<0x8006] == Data("CD001".utf8) {
                throw RPCError.invalidParams("That's an installer ISO, which needs a screen: a Linux machine starts from a cloud image's raw disk.")
            }
        default:
            throw RPCError.invalidParams("\(image.title) machines come from your SDK or Xcode: --file is for macOS (.ipsw) and Linux (a raw disk).")
        }
    }

    /// A Linux or macOS machine's exchange folder here (`~/Kelp` inside).
    /// Made here if it isn't yet (kelp-vm makes it too, as it starts the machine).
    func filesFolder(_ m: VMMachine) -> String? {
        guard ["linux", "macos"].contains(m.os) else { return nil }
        let files = file(m.name, "files")
        if !FileManager.default.fileExists(atPath: files.path) {
            do { try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true) } catch { Log.vm.error("\(m.name)'s files: \(error)") }
        }
        return files.path
    }

    /// New processors, memory and disk for a machine that's shut down; a disk only grows (Linux's root grows into it as
    /// it boots: cloud-init's growpart). A sleeping one's saved state wouldn't fit them: shut it down first.
    func configure(_ r: VMConfigure) throws -> VMInfo {
        var m = try machine(r.name)
        guard ["linux", "macos"].contains(m.os) else { throw RPCError.invalidParams("An \(m.os) machine's size is set when it's made.") }
        let state = info(m).state
        guard state == .off else {
            let why = state == .creating || state == .error ? "\(m.name) isn't made yet." : "Shut \(m.name) down first: a new size takes a fresh start."
            throw RPCError.invalidParams(why)
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount, gib = max(1, Int(ProcessInfo.processInfo.physicalMemory >> 30) / 2)
        let cpus = r.cpus ?? m.cpus, memory = r.memory ?? m.memoryMiB >> 10
        let disk = r.disk ?? m.diskGiB
        let least = m.os == "macos" ? 4 : 1
        guard (1...cores).contains(cpus), (least...max(least, gib)).contains(memory), (m.diskGiB...2048).contains(disk) else {
            let most = max(least, gib)
            throw RPCError.invalidParams("Processors 1–\(cores), memory \(least)–\(most) GB, disk \(m.diskGiB)–2048 GB (a disk only grows).")
        }
        // First: a kelp-vm left running with it off read the old size. Only if it's still down: a command could have woken
        // it since, and a quit then would cut its power.
        if alive(m.name) {
            let answer: VMHelper.Reply?
            do { answer = try ask(m.name, .init(op: .quit, args: ["if-down"]), wait: 10) } catch { answer = nil }   // it hangs up as it goes
            if let answer { try check(answer) }
            for _ in 0..<100 where alive(m.name) { usleep(100_000) }
        }
        // Held while the size changes: a kelp-vm a command starts meanwhile waits for it, then gives up, rather than boot
        // with the old size on a disk that grows under it.
        let lock = open(file(m.name, "kelp-vm.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        defer { if lock >= 0 { close(lock) } }
        // Tried for half a second: kelpd's own look at it (`alive`, shared) holds it a moment.
        var held = lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0
        for _ in 0..<10 where lock >= 0 && !held { usleep(50_000); held = flock(lock, LOCK_EX | LOCK_NB) == 0 }
        guard held else {
            throw RPCError.invalidParams("\(m.name) is in use again: shut it down, then change its size.")
        }
        if disk > m.diskGiB {
            guard m.os == "linux" else { throw RPCError.invalidParams("A macOS machine's disk can't grow: its recovery partition sits after it.") }
            guard truncate(file(m.name, "disk.img").path, off_t(disk) << 30) == 0 else {
                throw RPCError.internalError("Growing the disk: \(String(cString: strerror(errno)))")
            }
        }
        m.cpus = cpus
        m.memoryMiB = memory << 10
        m.diskGiB = disk
        try JSONEncoder().encode(m).write(to: file(m.name, "machine.json"), options: .atomic)
        return info(m)
    }
}

extension VMConfigure: Handled {
    var notForAgents: String? { "A machine's size is the user's: every chat's machine, and the Mac's memory." }
    func handle(_ vms: VMService) throws -> VMInfo { try vms.configure(self) }
}
