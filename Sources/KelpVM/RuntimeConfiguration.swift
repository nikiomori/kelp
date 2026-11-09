import Core
import Foundation
import Virtualization

extension Runtime {
    /// The machine as Virtualization runs it: a Linux one's EFI boot, cloud-init seed, console, balloon and Rosetta; a macOS
    /// one's (`MacGuest.configure`); and for both the disk, the NAT network, vsock and the share slots.
    static func configuration(_ machine: VMMachine, folder: URL, shares: [Int: String]) throws
        -> VZVirtualMachineConfiguration
    {
        func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = machine.cpus
        config.memorySize = UInt64(machine.memoryMiB) << 20
        let disk = VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(
                url: file("disk.img"), readOnly: false,
                cachingMode: .automatic, synchronizationMode: .fsync))
        if machine.os == "macos" {
            try MacGuest.configure(config, folder: folder)
            config.storageDevices = [disk]
        } else {
            let boot = VZEFIBootLoader()
            let vars = file("efi.vars")
            boot.variableStore =
                FileManager.default.fileExists(atPath: vars.path)
                ? VZEFIVariableStore(url: vars) : try VZEFIVariableStore(creatingVariableStoreAt: vars)
            config.bootLoader = boot
            let platform = VZGenericPlatformConfiguration()
            if let data = Data(contentsIfAny: file("machine.id")),
                let id = VZGenericMachineIdentifier(dataRepresentation: data)
            {
                platform.machineIdentifier = id
            } else {
                try platform.machineIdentifier.dataRepresentation.write(to: file("machine.id"))
            }
            config.platform = platform
            let seed = try VZDiskImageStorageDeviceAttachment(url: file("seed.iso"), readOnly: true)
            config.storageDevices = [disk, VZVirtioBlockDeviceConfiguration(attachment: seed)]
            config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
            let console = VZVirtioConsoleDeviceSerialPortConfiguration()
            console.attachment = try VZFileSerialPortAttachment(url: file("console.log"), append: false)
            config.serialPorts = [console]
        }
        if machine.network {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            let saved = String(contentsIfAny: file("mac"))
            if let mac = saved.flatMap({ VZMACAddress(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                net.macAddress = mac
            } else {
                try net.macAddress.string.write(to: file("mac"), atomically: true, encoding: .utf8)
            }
            config.networkDevices = [net]
        }
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.directorySharingDevices = (0..<VMs.shareSlots).map { slot in
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "kelp\(slot)")
            fs.share = shares[slot].flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                .map {
                    VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: $0), readOnly: false))
                }
            return fs
        }
        // The exchange folder, beside the machine on the Mac: one device after the slots, so their numbers stay.
        let files = folder.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let shared = VZSharedDirectory(url: files, readOnly: false)
        let exchange = VZVirtioFileSystemDeviceConfiguration(
            tag: machine.os == "macos" ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : VMs.filesTag)
        exchange.share =
            machine.os == "macos"
            ? VZMultipleDirectoryShare(directories: ["Kelp": shared]) : VZSingleDirectoryShare(directory: shared)
        config.directorySharingDevices.append(exchange)
        #if arch(arm64)   // Rosetta for Linux is Apple silicon's: an Intel Mac runs x86 guests as they are
            if machine.os == "linux", machine.rosetta, VZLinuxRosettaDirectoryShare.availability == .installed {
                let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                rosetta.share = try VZLinuxRosettaDirectoryShare()
                config.directorySharingDevices.append(rosetta)
            }
        #endif
        try config.validate()
        return config
    }
}
