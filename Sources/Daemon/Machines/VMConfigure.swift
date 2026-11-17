import Core
import Foundation

/// Handles a machine's files (the user's file it is made from, and its exchange folder) and its size, which changes
/// only while the machine is shut down.
extension VMService {
    /// Checks the file a machine is made from, before anything is made. It tells what the file is as far as the file's
    /// first bytes show.
    static func check(_ file: URL, for image: VMImage) throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RPCError.invalidParams("No file \(file.path).")
        }
        switch image.kind {
        case .macos:
            guard file.pathExtension.lowercased() == "ipsw" else {
                throw RPCError.invalidParams("A macOS machine is made from a restore image (.ipsw).")
            }
        case .linux:
            let handle = try FileHandle(forReadingFrom: file)
            defer { handle.closeFile() }
            let head = try handle.read(upToCount: 0x8006) ?? Data()
            if head.prefix(4) == Data([0x51, 0x46, 0x49, 0xFB]) {
                throw RPCError.invalidParams(
                    "That's a qcow2 image: Kelp runs raw disks. qemu-img convert -O raw \(file.lastPathComponent) disk.raw makes one."
                )
            }
            if head.count >= 0x8006, head[0x8001..<0x8006] == Data("CD001".utf8) {
                throw RPCError.invalidParams(
                    "That's an installer ISO, which needs a screen: a Linux machine starts from a cloud image's raw disk."
                )
            }
        case .android, .ios:
            throw RPCError.invalidParams(
                "\(image.title) machines come from your SDK or Xcode: --file is for macOS (.ipsw) and Linux (a raw disk)."
            )
        }
    }

    /// Returns the path on the Mac of a Linux or macOS machine's exchange folder, which is `~/Kelp` inside the machine.
    /// It makes the folder if it doesn't exist yet (kelp-vm makes it too, as it starts the machine).
    func filesFolder(_ machine: VMMachine) -> String? {
        guard machine.kind.sharesFolders else { return nil }
        let files = folder(machine.name).files
        if !FileManager.default.fileExists(atPath: files.path) {
            do { try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true) } catch {
                Log.vm.error("\(machine.name)'s files: \(error)")
            }
        }
        return files.path
    }

    /// Sets new processors, memory and disk size for a machine that's shut down. A disk only grows, and Linux's root
    /// partition grows into the new space as it boots (cloud-init's growpart). A sleeping machine's saved state
    /// wouldn't fit the new size, so the machine has to be shut down first.
    func configure(_ request: VMConfigure) throws -> VMInfo {
        var machine = try self.machine(request.name)
        guard machine.kind.resizable else {
            throw RPCError.invalidParams("An \(machine.os) machine's size is set when it's made.")
        }
        let state = info(machine).state
        guard state == .off else {
            let why =
                state == .creating || state == .error
                ? "\(machine.name) isn't made yet." : "Shut \(machine.name) down first: a new size takes a fresh start."
            throw RPCError.invalidParams(why)
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount, memories = machine.kind.memoryRange()
        let cpus = request.cpus ?? machine.cpus, memory = request.memory ?? machine.memoryMiB >> 10
        let disk = request.disk ?? machine.diskGiB
        guard (1...cores).contains(cpus), memories.contains(memory), (machine.diskGiB...2048).contains(disk) else {
            throw RPCError.invalidParams(
                "Processors 1–\(cores), memory \(memories.lowerBound)–\(memories.upperBound) GB, disk \(machine.diskGiB)–2048 GB "
                    + "(a disk only grows)."
            )
        }
        // First, a kelp-vm still running while the machine is off has read the old size, so it is asked to quit. It
        // quits only if the machine is still down, because a command could have woken the machine since, and quitting
        // then would cut its power.
        if alive(machine.name) {
            let answer: VMHelper.Reply?
            // kelp-vm may hang up as it quits, so no answer counts as no error.
            do { answer = try ask(machine.name, .quitIfDown, wait: 10) } catch { answer = nil }
            if let answer { try check(answer) }
            for _ in 0..<100 where alive(machine.name) { usleep(100_000) }
        }
        // This lock is held while the size changes. A kelp-vm that a command starts meanwhile waits for the lock and
        // then gives up, rather than boot with the old size on a disk that grows under it.
        let lock = open(folder(machine.name).lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        defer { if lock >= 0 { close(lock) } }
        // Taking the lock is tried for half a second, because kelpd's own check (`alive`, a shared lock) holds it
        // for a moment.
        var held = lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0
        for _ in 0..<10 where lock >= 0 && !held {
            usleep(50_000)
            held = flock(lock, LOCK_EX | LOCK_NB) == 0
        }
        guard held else {
            throw RPCError.invalidParams("\(machine.name) is in use again: shut it down, then change its size.")
        }
        if disk > machine.diskGiB {
            guard machine.kind == .linux else {
                throw RPCError.invalidParams("A macOS machine's disk can't grow: its recovery partition sits after it.")
            }
            // This goes by the disk file's own size, not the size in machine.json, so a disk that grew before a failed
            // write of machine.json is never cut back.
            let path = folder(machine.name).disk.path
            var st = stat()
            guard stat(path, &st) == 0 else {
                throw RPCError.internalError("Reading the disk's size: \(String(cString: strerror(errno)))")
            }
            if st.st_size < off_t(disk) << 30, truncate(path, off_t(disk) << 30) != 0 {
                throw RPCError.internalError("Growing the disk: \(String(cString: strerror(errno)))")
            }
        }
        machine.cpus = cpus
        machine.memoryMiB = memory << 10
        machine.diskGiB = disk
        try JSONEncoder().encode(machine).write(to: folder(machine.name).machine, options: .atomic)
        return info(machine)
    }
}

extension VMConfigure: Handled {
    var fence: Fence {
        Fence(notForAgents: "A machine's size is the user's: every chat's machine, and the Mac's memory.")
    }
    func handle(_ vms: VMService) throws -> VMInfo { try vms.configure(self) }
}

extension Methods {
    static let vmConfigureMethods: [any Answered.Type] = [VMConfigure.self]
}
