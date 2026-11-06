import Foundation
import Virtualization
import Core

extension Runtime {
    /// The machine as Virtualization runs it: a Linux one's EFI boot, cloud-init seed, console, balloon and Rosetta; a macOS
    /// one's (`MacGuest.configure`); and for both the disk, the NAT network, vsock and the share slots.
    static func configuration(_ m: VMMachine, folder: URL, shares: [Int: String]) throws -> VZVirtualMachineConfiguration {
        func file(_ n: String) -> URL { folder.appendingPathComponent(n) }
        let c = VZVirtualMachineConfiguration()
        c.cpuCount = m.cpus
        c.memorySize = UInt64(m.memoryMiB) << 20
        let disk = VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: file("disk.img"), readOnly: false,
                                                                                                      cachingMode: .automatic, synchronizationMode: .fsync))
        if m.os == "macos" {
            try MacGuest.configure(c, folder: folder)
            c.storageDevices = [disk]
        } else {
            let boot = VZEFIBootLoader()
            let vars = file("efi.vars")
            boot.variableStore = FileManager.default.fileExists(atPath: vars.path)
                ? VZEFIVariableStore(url: vars) : try VZEFIVariableStore(creatingVariableStoreAt: vars)
            c.bootLoader = boot
            let platform = VZGenericPlatformConfiguration()
            if let d = try? Data(contentsOf: file("machine.id")), let id = VZGenericMachineIdentifier(dataRepresentation: d) { platform.machineIdentifier = id }
            else { try platform.machineIdentifier.dataRepresentation.write(to: file("machine.id")) }
            c.platform = platform
            let seed = try VZDiskImageStorageDeviceAttachment(url: file("seed.iso"), readOnly: true)
            c.storageDevices = [disk, VZVirtioBlockDeviceConfiguration(attachment: seed)]
            c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
            let console = VZVirtioConsoleDeviceSerialPortConfiguration()
            console.attachment = try VZFileSerialPortAttachment(url: file("console.log"), append: false)
            c.serialPorts = [console]
        }
        if m.network {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            let saved = try? String(contentsOf: file("mac"), encoding: .utf8)
            if let mac = saved.flatMap({ VZMACAddress(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                net.macAddress = mac
            } else { try net.macAddress.string.write(to: file("mac"), atomically: true, encoding: .utf8) }
            c.networkDevices = [net]
        }
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        c.directorySharingDevices = (0..<VMs.shareSlots).map { slot in
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "kelp\(slot)")
            fs.share = shares[slot].flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                .map { VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: $0), readOnly: false)) }
            return fs
        }
        // The exchange folder, beside the machine on the Mac: one device after the slots, so their numbers stay.
        let files = folder.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let shared = VZSharedDirectory(url: files, readOnly: false)
        let exchange = VZVirtioFileSystemDeviceConfiguration(tag: m.os == "macos" ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : VMs.filesTag)
        exchange.share = m.os == "macos" ? VZMultipleDirectoryShare(directories: ["Kelp": shared]) : VZSingleDirectoryShare(directory: shared)
        c.directorySharingDevices.append(exchange)
        #if arch(arm64)   // Rosetta for Linux is Apple silicon's: an Intel Mac runs x86 guests as they are
        if m.os == "linux", m.rosetta, VZLinuxRosettaDirectoryShare.availability == .installed {
            let r = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            r.share = try VZLinuxRosettaDirectoryShare()
            c.directorySharingDevices.append(r)
        }
        #endif
        try c.validate()
        return c
    }
}
