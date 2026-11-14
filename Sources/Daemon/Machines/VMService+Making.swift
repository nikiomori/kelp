import Core
import CryptoKit
import Foundation
import os

// Making a machine: its image downloaded, checked and unpacked into its folder, step by step.

extension VMService {
    /// A property, not `#if` around a `throw`: Intel's build would warn that the rest of `create` is never run.
    private static var appleSilicon: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }

    func create(_ request: VMCreate) throws -> VMInfo {
        guard Self.appleSilicon else {
            throw RPCError.invalidParams("Machines need a Mac with Apple silicon: their images are for ARM.")
        }
        guard VMs.isName(request.name) else {
            throw RPCError.invalidParams(
                "A machine's name: up to 20 lowercase letters, digits and dashes, starting with a letter.")
        }
        // One whose making failed, asked for again as it was (no image, file or size): made again from what it is.
        let asItWas = [request.cpus, request.memory, request.disk].allSatisfy { $0 == nil }
        if failure(request.name) != nil, request.image == nil, request.file == nil, asItWas {
            let vm = try machine(request.name)
            makeAgain(vm)
            return info(vm)
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
        let cores = ProcessInfo.processInfo.activeProcessorCount, kind = image.kind, memories = kind.memoryRange()
        let cpus = request.cpus ?? (kind == .macos ? 4 : 2), memory = request.memory ?? (kind == .macos ? 6 : 2),
            disk = request.disk ?? [.macos: 64, .linux: 32][kind] ?? 8
        guard (1...cores).contains(cpus), memories.contains(memory), (8...2048).contains(disk) else {
            throw RPCError.invalidParams(
                "--cpus 1–\(cores), --memory \(memories.lowerBound)–\(memories.upperBound) GB, --disk 8–2048 GB.")
        }
        let machine = VMMachine(
            name: request.name, os: image.os, image: image.id, cpus: cpus, memoryMiB: memory << 10, diskGiB: disk,
            user: VMs.user(NSUserName()), rosetta: kind == .linux)
        let machineFolder = folder(machine.name).url
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
        step(machine, kind == .macos && given == nil ? .asking : .starting)
        // to go on after a restart
        if let given { try given.path.write(to: folder(machine.name).source, atomically: true, encoding: .utf8) }
        try JSONEncoder().encode(machine).write(to: folder(machine.name).machine)
        Task.detached {
            switch kind {
            case .macos: await self.makeMac(machine, ipsw: given)
            case .android: await self.makeAndroid(machine)
            case .ios: await self.makeIOS(machine)
            case .linux: await self.make(machine, image, raw: given)
            }
        }
        return info(machine)
    }

    /// Notes how far making it got; false once it's been deleted midway (Stop Making), for a download to stop at.
    @discardableResult
    func step(_ machine: VMMachine, _ step: VMStep, _ detail: String? = nil, progress: Double? = nil) -> Bool {
        guard !deleted(machine.name) else { return false }
        let at = VMMaking(step: step, progress: progress, detail: detail)
        Log.vm.attempt("noting \(machine.name)'s progress") {
            try at.data.write(to: folder(machine.name).creating, options: .atomic)
        }
        return true
    }

    /// Its folder gone while it was being made: the user stopped making it.
    func deleted(_ name: String) -> Bool { !FileManager.default.fileExists(atPath: folder(name).machine.path) }

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
            if deleted(machine.name) {   // stopped by the user: its programs ended, its folder gone with its disk
                Log.vm.info("making \(machine.name) stopped: it was deleted")
                Keychain.delete("vm." + machine.name)   // a macOS one's password, if it was set after the delete
                return
            }
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
                try Data(why.utf8).write(to: folder(machine.name).failed)
            }
        }
        remove(folder(machine.name).creating)
    }

    /// The image's raw disk, downloaded and checked the first time.
    private func image(_ image: VMImage, progress: @escaping @Sendable (VMStep, Double?) -> Bool) async throws -> URL {
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
        // Kept beside the images until it's unpacked: a kelpd that restarts midway goes on where this one stopped.
        // Limit: two machines of an image made at once share the download; the one that unpacks it second may find the
        // archive gone and fail (made again, it finds the image unpacked).
        let archive = images.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: archive.path) {
            try await download(image.url, to: archive) { progress(.downloading, $0) }
        }
        defer { remove(archive) }
        _ = progress(.checking, nil)
        guard try await blocking({ try Self.sha512(archive) }) == want else {
            throw RPCError.internalError("\(name) doesn't match its published checksum: not used")
        }
        _ = progress(.unpacking, nil)
        let dir = images.appendingPathComponent(".unpack-\(image.id)-\(UUID().uuidString.prefix(8))")   // another make may unpack too
        try Paths.ensure(dir)
        defer { remove(dir) }
        let out = try await Subprocess.run(
            ["/usr/bin/tar", "-xf", archive.path, "-C", dir.path, image.member], cwd: "/", env: [:], timeLimit: 600)
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
        return sha.finalize().hex
    }

    /// The machine's folder: its disk (an APFS clone of the image, grown), key, cloud-init seed, ssh_config.
    private func makeFolder(_ machine: VMMachine, from raw: URL) throws {
        let disk = folder(machine.name).disk
        try FileManager.default.copyItem(at: raw, to: disk)   // clonefile on APFS: no space taken until it differs
        guard truncate(disk.path, off_t(machine.diskGiB) << 30) == 0 else {
            throw RPCError.internalError("can't size the disk: \(String(cString: strerror(errno)))")
        }
        let key = folder(machine.name).key
        try run([
            "/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "kelp-vm-" + machine.name, "-f", key.path
        ])
        let seed = folder(machine.name).file(".seed")
        try Paths.ensure(seed)
        defer { remove(seed) }
        let pub = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        try VMs.userData(machine, publicKey: pub, timeZone: TimeZone.current.identifier)
            .write(to: seed.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try "instance-id: \(UUID().uuidString)\nlocal-hostname: \(machine.name)\n"
            .write(to: seed.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        try run([
            "/usr/bin/hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
            "-o", folder(machine.name).seed.path, seed.path
        ])
        try VMs.sshConfig(machine, folder: folder(machine.name)).write(
            to: folder(machine.name).sshConfig, atomically: true, encoding: .utf8)
    }

    /// curl, which goes on where it stopped (`-C -`); how far (0…1, nil while that's unknown), every few seconds, from a
    /// thread of its own. A file still growing is another curl's (a kelpd before this one started it): waited for, not
    /// downloaded twice. `progress` false (the machine was deleted midway): curl ended and what it got dropped.
    func download(_ url: String, to file: URL, progress: @escaping @Sendable (Double?) -> Bool) async throws {
        let part = file.appendingPathExtension("part")
        let head = try await blocking { try run(["/usr/bin/curl", "-fsIL", url], limit: 60) }
        let total = Self.contentLength(head)
        @Sendable func size() -> Double {
            var st = stat()
            return stat(part.path, &st) == 0 ? Double(st.st_size) : 0
        }
        while true {   // another curl's, still writing
            let before = size()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            if size() == before { break }
            guard progress(total > 0 ? size() / total : nil) else { throw CancellationError() }
        }
        if FileManager.default.fileExists(atPath: file.path) { return }   // the other one finished it
        let done = OSAllocatedUnfairLock(initialState: false)
        Thread.detachNewThread {
            while !done.withLock({ $0 }) {
                guard progress(total > 0 ? min(1, size() / total) : nil) else {
                    Log.vm.attempt("stopping \(file.lastPathComponent)'s download") {
                        _ = try Subprocess.run(
                            ["/usr/bin/pkill", "-TERM", "-f", "--", Self.inFolder(part.path)], cwd: "/", env: [:],
                            timeLimit: 10)
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 3)
            }
        }
        defer { done.withLock { $0 = true } }
        if total == 0 || size() < total {
            let curl = ["/usr/bin/curl", "-fsSL", "--retry", "5", "-C", "-", "-o", part.path, url]
            let out = try await Subprocess.run(curl, cwd: "/", env: [:], timeLimit: 6 * 3600)
            guard out.status == 0 else {
                if !progress(nil) {   // stopped: what it got is no one's now (20 GB of macOS, half of it)
                    remove(part)
                    throw CancellationError()
                }
                throw RPCError.internalError(
                    "Downloading \(file.lastPathComponent): " + String(decoding: out.stderr, as: UTF8.self))
            }
        }
        try FileManager.default.moveItem(at: part, to: file)
    }

    /// The last Content-Length of curl -I's headers (after redirects). Header lines end in CRLF, which Swift reads as one
    /// Character: split on newlines, not on "\n".
    static func contentLength(_ headers: String) -> Double {
        let line = headers.components(separatedBy: .newlines).last { $0.lowercased().hasPrefix("content-length:") }
        return line.flatMap { Double($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
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
