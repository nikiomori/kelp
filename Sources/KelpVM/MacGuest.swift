import Core
import Foundation
import Virtualization

/// What a macOS machine needs that a Linux one doesn't: Apple's boot loader and platform (its hardware model, identity and
/// auxiliary storage, made when it's installed), a Mac display, keyboard and trackpad; its installation from a restore
/// image; and reaching its sshd, which listens on TCP only, at its address on the NAT network.
@MainActor
enum MacGuest {
    /// 1280 × 800 points at 2×: sharp on a Retina screen, small enough for an agent's screenshots.
    static let display = (width: 2560, height: 1600, ppi: 220)

    /// Virtualization runs macOS only on Apple silicon: an Intel Mac (a universal build's other half) says so.
    static let needsAppleSilicon = VMError("macOS machines need a Mac with Apple silicon.")

    static func configure(_ c: VZVirtualMachineConfiguration, folder: URL) throws {
        #if arch(arm64)
            func file(_ n: String) -> URL { folder.appendingPathComponent(n) }
            let platform = VZMacPlatformConfiguration()
            guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: file("hardware.bin"))),
                model.isSupported,
                let id = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: file("machine.id")))
            else {
                throw VMError("This Mac can't run this machine's hardware model.")
            }
            platform.hardwareModel = model
            platform.machineIdentifier = id
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: file("aux.bin"))
            c.platform = platform
            c.bootLoader = VZMacOSBootLoader()
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [
                VZMacGraphicsDisplayConfiguration(
                    widthInPixels: display.width, heightInPixels: display.height,
                    pixelsPerInch: display.ppi)
            ]
            c.graphicsDevices = [graphics]
            c.keyboards = [VZMacKeyboardConfiguration()]
            c.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        #else
            throw needsAppleSilicon
        #endif
    }

    /// The restore image's hardware model, a new identity and auxiliary storage, a sparse disk: then macOS installed on it,
    /// `progress` 0…1 as it goes.
    static func install(
        _ m: VMMachine, folder: URL, ipsw: URL, progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        #if arch(arm64)
            func file(_ n: String) -> URL { folder.appendingPathComponent(n) }
            let image = try await VZMacOSRestoreImage.image(from: ipsw)
            guard let needs = image.mostFeaturefulSupportedConfiguration else {
                throw VMError("This Mac can't run macOS \(image.buildVersion).")
            }
            guard m.cpus >= needs.minimumSupportedCPUCount,
                UInt64(m.memoryMiB) << 20 >= needs.minimumSupportedMemorySize
            else {
                throw VMError(
                    "macOS \(image.buildVersion) needs \(needs.minimumSupportedCPUCount) CPUs and "
                        + "\(needs.minimumSupportedMemorySize >> 30) GB of memory at least.")
            }
            try needs.hardwareModel.dataRepresentation.write(to: file("hardware.bin"))
            try VZMacMachineIdentifier().dataRepresentation.write(to: file("machine.id"))
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: file("aux.bin"), hardwareModel: needs.hardwareModel, options: [.allowOverwrite])
            let disk = file("disk.img")
            guard FileManager.default.createFile(atPath: disk.path, contents: nil),
                truncate(disk.path, off_t(m.diskGiB) << 30) == 0
            else {
                throw VMError("Can't make the disk: \(String(cString: strerror(errno)))")
            }
            let vm = VZVirtualMachine(configuration: try Runtime.configuration(m, folder: folder, shares: [:]))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            let watching = installer.progress.observe(\.fractionCompleted) { p, _ in
                let f = p.fractionCompleted
                DispatchQueue.main.async { MainActor.assumeIsolated { progress(f) } }
            }
            defer { watching.invalidate() }
            try await installer.install()
        #else
            throw needsAppleSilicon
        #endif
    }

    /// Apple's latest restore image this Mac can run: its address and build.
    static func latest() async throws -> (url: URL, build: String, version: String) {
        #if arch(arm64)
            let image = try await VZMacOSRestoreImage.latestSupported
            let v = image.operatingSystemVersion
            return (
                image.url, image.buildVersion,
                "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
            )
        #else
            throw needsAppleSilicon
        #endif
    }

    #if arch(arm64)
        /// The first boot sets the account up by itself, signs in and turns Remote Login on (macOS 27 hosts and guests).
        static func firstStart(_ m: VMMachine, password: String) throws -> VZMacOSVirtualMachineStartOptions {
            let options = VZMacOSVirtualMachineStartOptions()
            if #available(macOS 27.0, *) {
                let p = VZMacGuestProvisioningOptions()
                p.fullName = m.user
                p.username = m.user
                p.password = password
                p.logsInAutomatically = true
                p.enablesRemoteLogin = true
                try options.setGuestProvisioning(p)
            }
            return options
        }
    #endif

    /// Its address on the NAT network: the newest lease bootpd gave its MAC (`1,<mac>`, each byte without its leading zero).
    static func address(mac: String) -> String? {
        let want =
            "1,"
            + mac.lowercased().split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(
                separator: ":")
        guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        var best: (ip: String, lease: Int)?
        for block in leases.components(separatedBy: "}") {
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                let kv = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            guard fields["hw_address"] == want, let ip = fields["ip_address"] else { continue }
            let lease = Int(fields["lease"]?.replacingOccurrences(of: "0x", with: "") ?? "", radix: 16) ?? 0
            if lease >= best?.lease ?? -1 { best = (ip, lease) }
        }
        return best?.ip
    }

    /// The guest's sshd joined to `client` by /usr/bin/nc, which holds the client's socket as its stdin and stdout: macOS's
    /// Local Network privacy refuses programs of ours an address on the machines' NAT network ("No route to host"), and
    /// lets the system's own through. `ended` comes on the main queue when it's over.
    static func bridge(_ client: Int32, to ip: String, ended: @escaping @MainActor @Sendable () -> Void) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = [ip, "22"]
        let socket = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        p.standardInput = socket
        p.standardOutput = socket
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { ended() } } }
        do { try p.run() } catch {
            log("nc: \(error)")
            return false
        }
        return true
    }

    /// Whether the guest's sshd answers with its banner (through /usr/bin/nc, as `bridge`).
    nonisolated static func banner(_ ip: String) -> Bool {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-G", "2", ip, "22"]
        p.standardInput = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        defer { p.terminate() }
        var pfd = pollfd(fd: out.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 3000) > 0 else { return false }
        return out.fileHandleForReading.availableData.prefix(4) == Data("SSH-".utf8)
    }
}
