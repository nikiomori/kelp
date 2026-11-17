import Core
import Foundation
import Virtualization

/// What a macOS machine needs that a Linux one doesn't. That is Apple's boot loader and platform (the hardware model,
/// identity and auxiliary storage, made when the machine is installed), and a Mac display, keyboard and trackpad. It
/// also covers installing macOS from a restore image, and reaching the machine's sshd, which listens on TCP only, at
/// the machine's address on the NAT network.
@MainActor
enum MacGuest {
    /// The display is 1280 × 800 points at 2×, which is sharp on a Retina screen and small enough for an agent's
    /// screenshots.
    static let display = (width: 2560, height: 1600, ppi: 220)

    /// Virtualization runs macOS only on Apple silicon, so on an Intel Mac (the other half of a universal build) this
    /// error says so.
    static let needsAppleSilicon = VMError("macOS machines need a Mac with Apple silicon.")

    static func configure(_ config: VZVirtualMachineConfiguration, folder: URL) throws {
        #if arch(arm64)
            func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
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
            config.platform = platform
            config.bootLoader = VZMacOSBootLoader()
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [
                VZMacGraphicsDisplayConfiguration(
                    widthInPixels: display.width, heightInPixels: display.height,
                    pixelsPerInch: display.ppi)
            ]
            config.graphicsDevices = [graphics]
            config.keyboards = [VZMacKeyboardConfiguration()]
            config.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        #else
            throw needsAppleSilicon
        #endif
    }

    /// Installs macOS into the machine's folder. It first writes the restore image's hardware model, a new identity,
    /// new auxiliary storage and a sparse disk, and then installs macOS on that disk. `progress` gets 0…1 as it goes.
    static func install(
        _ machine: VMMachine, folder: URL, ipsw: URL, progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        #if arch(arm64)
            func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
            let image = try await VZMacOSRestoreImage.image(from: ipsw)
            guard let needs = image.mostFeaturefulSupportedConfiguration else {
                throw VMError("This Mac can't run macOS \(image.buildVersion).")
            }
            guard machine.cpus >= needs.minimumSupportedCPUCount,
                UInt64(machine.memoryMiB) << 20 >= needs.minimumSupportedMemorySize
            else {
                throw VMError(
                    "macOS \(image.buildVersion) needs \(needs.minimumSupportedCPUCount) CPUs and "
                        + "\(needs.minimumSupportedMemorySize >> 30) GB of memory at least.")
            }
            try needs.hardwareModel.dataRepresentation.write(to: file("hardware.bin"))
            try VZMacMachineIdentifier().dataRepresentation.write(to: file("machine.id"))
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: file("aux.bin"), hardwareModel: needs.hardwareModel, options: [.allowOverwrite])
            let disk = VMFolder(folder).disk
            guard FileManager.default.createFile(atPath: disk.path, contents: nil),
                truncate(disk.path, off_t(machine.diskGiB) << 30) == 0
            else {
                throw VMError("Can't make the disk: \(String(cString: strerror(errno)))")
            }
            let vm = VZVirtualMachine(configuration: try Runtime.configuration(machine, folder: folder, shares: [:]))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            let watching = installer.progress.observe(\.fractionCompleted) { observed, _ in
                let fraction = observed.fractionCompleted
                DispatchQueue.main.async { MainActor.assumeIsolated { progress(fraction) } }
            }
            defer { watching.invalidate() }
            try await installer.install()
        #else
            throw needsAppleSilicon
        #endif
    }

    /// Returns the address, build and version of Apple's latest restore image that this Mac can run.
    static func latest() async throws -> (url: URL, build: String, version: String) {
        #if arch(arm64)
            let image = try await VZMacOSRestoreImage.latestSupported
            let version = image.operatingSystemVersion
            return (
                image.url, image.buildVersion,
                "\(version.majorVersion).\(version.minorVersion)"
                    + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
            )
        #else
            throw needsAppleSilicon
        #endif
    }

    #if arch(arm64)
        /// Returns start options with which the first boot sets the account up by itself, signs in and turns Remote
        /// Login on. Only macOS 27 hosts and guests can do this.
        static func firstStart(_ machine: VMMachine, password: String) throws -> VZMacOSVirtualMachineStartOptions {
            let options = VZMacOSVirtualMachineStartOptions()
            if #available(macOS 27.0, *) {
                let provisioning = VZMacGuestProvisioningOptions()
                provisioning.fullName = machine.user
                provisioning.username = machine.user
                provisioning.password = password
                provisioning.logsInAutomatically = true
                provisioning.enablesRemoteLogin = true
                try options.setGuestProvisioning(provisioning)
            }
            return options
        }
    #endif

    /// Returns the machine's address on the NAT network. That is the newest lease bootpd gave the machine's MAC, which
    /// the leases file writes as `1,<mac>` with each byte missing its leading zero.
    static func address(mac: String) -> String? {
        let want =
            "1,"
            + mac.lowercased().split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(
                separator: ":")
        guard let leases = String(contentsIfAny: URL(fileURLWithPath: "/var/db/dhcpd_leases")) else { return nil }
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

    /// Joins `client` to the guest's sshd through /usr/bin/nc, which holds the client's socket as its stdin and stdout.
    /// nc does it because macOS's Local Network privacy refuses Kelp's own programs an address on the machines' NAT
    /// network ("No route to host") but lets the system's programs through. `ended` is called on the main queue when
    /// the connection is over.
    static func bridge(_ client: Int32, to ip: String, ended: @escaping @MainActor @Sendable () -> Void) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = [ip, "22"]
        let socket = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        process.standardInput = socket
        process.standardOutput = socket
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { ended() } } }
        do { try process.run() } catch {
            log("nc: \(error)")
            return false
        }
        return true
    }

    /// Returns whether the guest's sshd answers with its banner. It asks through /usr/bin/nc, as `bridge` does.
    nonisolated static func banner(_ ip: String) -> Bool {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-G", "2", ip, "22"]
        process.standardInput = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        defer { process.terminate() }
        var pfd = pollfd(fd: out.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 3000) > 0 else { return false }
        return out.fileHandleForReading.availableData.prefix(4) == Data("SSH-".utf8)
    }
}
