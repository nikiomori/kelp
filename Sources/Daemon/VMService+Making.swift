import Core
import CryptoKit
import Foundation
import os

// Making a machine: its image downloaded, checked and unpacked into its folder, step by step.

extension VMService {
    func create(_ request: VMCreate) throws -> VMInfo {
        #if arch(x86_64)
            throw RPCError.invalidParams("Machines need a Mac with Apple silicon: their images are for ARM.")
        #endif
        guard VMs.isName(request.name) else {
            throw RPCError.invalidParams(
                "A machine's name: up to 20 lowercase letters, digits and dashes, starting with a letter.")
        }
        let given = request.file.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let id =
            request.image ?? (given.map { $0.pathExtension.lowercased() == "ipsw" ? "macos" : "linux" } ?? "debian-13")
        guard let image = VMImage.named(id) else {
            throw RPCError.invalidParams("No image \(id). There are: \(VMImage.all.map(\.id).joined(separator: ", ")).")
        }
        if let given {
            try Self.check(given, for: image)
        } else if id == "linux" {
            throw RPCError.invalidParams(
                "A Linux machine of your own is made from its disk: --file disk.raw (or --image debian-13).")
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount,
            gib = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        let mac = image.os == "macos"
        let cpus = request.cpus ?? (mac ? 4 : 2), memory = request.memory ?? (mac ? 6 : 2),
            disk = request.disk ?? (mac ? 64 : ["android", "ios"].contains(image.os) ? 8 : 32)
        guard (1...cores).contains(cpus), (1...max(1, gib / 2)).contains(memory), (8...2048).contains(disk) else {
            throw RPCError.invalidParams("--cpus 1–\(cores), --memory 1–\(max(1, gib / 2)) GB, --disk 8–2048 GB.")
        }
        let machine = VMMachine(
            name: request.name, os: image.os, image: image.id, cpus: cpus, memoryMiB: memory << 10, diskGiB: disk,
            user: VMs.user(NSUserName()), rosetta: image.os == "linux")
        let machineFolder = folder(machine.name)
        // an earlier try's remains, its simulator and password with it
        if failure(machine.name) != nil { try discard(machine.name) }
        try Paths.ensure(root)
        do {
            try FileManager.default.createDirectory(at: machineFolder, withIntermediateDirectories: false)
        } catch CocoaError
            .fileWriteFileExists
        {
            throw RPCError.invalidParams("There's already a machine called \(machine.name).")
        }
        chmod(machineFolder.path, 0o700)
        step(machine, image.os == "macos" && given == nil ? .asking : .starting)
        // to go on after a restart
        if let given { try given.path.write(to: file(machine.name, "source"), atomically: true, encoding: .utf8) }
        try JSONEncoder().encode(machine).write(to: file(machine.name, "machine.json"))
        Task.detached {
            switch image.os {
            case "macos": await self.makeMac(machine, ipsw: given)
            case "android": await self.makeAndroid(machine)
            case "ios": await self.makeIOS(machine)
            default: await self.make(machine, image, raw: given)
            }
        }
        return info(machine)
    }

    func step(_ machine: VMMachine, _ step: VMStep, _ detail: String? = nil, progress: Double? = nil) {
        let at = VMMaking(step: step, progress: progress, detail: detail)
        Log.vm.attempt("noting \(machine.name)'s progress") {
            try at.data.write(to: file(machine.name, "creating"), options: .atomic)
        }
    }

    func make(_ machine: VMMachine, _ image: VMImage, raw given: URL? = nil) async {
        await making(machine) {
            let raw: URL
            if let given {
                raw = given
            } else {
                raw = try await self.image(image) { step(machine, $0, image.title, progress: $1) }
            }
            step(machine, .disk)
            try await blocking { try makeFolder(machine, from: raw) }
            step(machine, .starting)
            try await blocking {
                try startHelper(machine)
                try check(ask(machine.name, .init(op: .start), wait: 620))
            }
        }
    }

    /// Slow work that waits on a program or a socket: on a thread of its own, never one of Swift's few pool threads.
    func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Runs the steps of making `machine`; its `creating` file goes when they end, and why they failed stays in
    /// `failed`.
    func making(_ machine: VMMachine, _ steps: () async throws -> Void) async {
        do { try await steps() } catch {
            Log.vm.error("making \(machine.name): \(error)")
            // A machine half made holds memory for nothing: shut down as the guest would (a power cut loses what was just
            // written into it, Kelp Guest's app included), then its kelp-vm gone.
            let stop: @Sendable () -> Void = { [self] in   // up to a minute: not on a thread of the shared pool
                if status(machine.name) != nil {
                    do { _ = try ask(machine.name, .init(op: .stop), wait: 60) } catch {
                        Log.vm.info("\(machine.name) stop: \(error)")
                    }
                }
                quit(machine.name)
            }
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    stop()
                    continuation.resume()
                }
            }
            let why = (error as? RPCError)?.message ?? error.localizedDescription
            Log.vm.attempt("noting why \(machine.name) failed") {
                try Data(why.utf8).write(to: file(machine.name, "failed"))
            }
        }
        remove(file(machine.name, "creating"))
    }

    /// The image's raw disk, downloaded and checked the first time.
    private func image(_ image: VMImage, progress: @escaping @Sendable (VMStep, Double?) -> Void) async throws -> URL {
        let raw = images.appendingPathComponent(image.id + ".raw")
        if FileManager.default.fileExists(atPath: raw.path) { return raw }
        try Paths.ensure(images)
        guard let url = URL(string: image.url), let sumsURL = URL(string: image.sums) else {
            throw RPCError.internalError("bad image address")
        }
        let (sums, _) = try await URLSession.shared.data(from: sumsURL)
        let name = url.lastPathComponent
        let line = String(decoding: sums, as: UTF8.self).split(separator: "\n").first { $0.hasSuffix("  " + name) }
        guard let want = line?.split(separator: " ").first else {
            throw RPCError.internalError("\(name) isn't in \(image.sums)")
        }
        let watcher = DownloadProgress { progress(.downloading, $0) }
        let (tmp, _) = try await URLSession.shared.download(from: url, delegate: watcher)
        defer { remove(tmp) }
        progress(.checking, nil)
        guard try await blocking({ try Self.sha512(tmp) }) == want else {
            throw RPCError.internalError("\(name) doesn't match its published checksum: not used")
        }
        progress(.unpacking, nil)
        let dir = images.appendingPathComponent(".unpack-\(image.id)-\(UUID().uuidString.prefix(8))")   // another make may unpack too
        try Paths.ensure(dir)
        defer { remove(dir) }
        let out = try await Subprocess.run(
            ["/usr/bin/tar", "-xf", tmp.path, "-C", dir.path, image.member], cwd: "/", env: [:], timeLimit: 600)
        guard out.status == 0 else {
            throw RPCError.internalError("tar: " + String(decoding: out.stderr, as: UTF8.self))
        }
        if !FileManager.default.fileExists(atPath: raw.path) {   // else another make unpacked it first
            try FileManager.default.moveItem(at: dir.appendingPathComponent(image.member), to: raw)
        }
        return raw
    }

    static func sha512(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { handle.closeFile() }
        var sha = SHA512()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The machine's folder: its disk (an APFS clone of the image, grown), key, cloud-init seed, ssh_config.
    private func makeFolder(_ machine: VMMachine, from raw: URL) throws {
        let disk = file(machine.name, "disk.img")
        try FileManager.default.copyItem(at: raw, to: disk)   // clonefile on APFS: no space taken until it differs
        guard truncate(disk.path, off_t(machine.diskGiB) << 30) == 0 else {
            throw RPCError.internalError("can't size the disk: \(String(cString: strerror(errno)))")
        }
        let key = file(machine.name, "id_ed25519")
        try run([
            "/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "kelp-vm-" + machine.name, "-f", key.path
        ])
        let seed = file(machine.name, ".seed")
        try Paths.ensure(seed)
        defer { remove(seed) }
        let pub = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        try VMs.userData(machine, publicKey: pub, timeZone: TimeZone.current.identifier)
            .write(to: seed.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try "instance-id: \(UUID().uuidString)\nlocal-hostname: \(machine.name)\n"
            .write(to: seed.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        try run([
            "/usr/bin/hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
            "-o", file(machine.name, "seed.iso").path, seed.path
        ])
        try VMs.sshConfig(machine, folder: folder(machine.name)).write(
            to: file(machine.name, "ssh_config"), atomically: true, encoding: .utf8)
    }

    /// A program's output; its error when it fails.
    @discardableResult
    func run(_ argv: [String], limit: TimeInterval = 60) throws -> String {
        let out = try Subprocess.run(argv, cwd: "/", env: [:], timeLimit: limit)
        guard out.status == 0 else {
            throw RPCError.internalError(
                (argv[0] as NSString).lastPathComponent + ": " + String(decoding: out.stderr, as: UTF8.self))
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
        let observation = task.progress.observe(\.fractionCompleted) { [weak self, report] progress, _ in
            let percent = Int(progress.fractionCompleted * 100)   // a percent at a time, not every few kilobytes
            guard
                self?.watching.withLock({ current in
                    defer { current.percent = percent }
                    return current.percent != percent
                }) == true
            else { return }
            report(progress.fractionCompleted)
        }
        watching.withLock { $0.0 = observation }
    }
}
