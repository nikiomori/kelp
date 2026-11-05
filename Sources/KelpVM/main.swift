import AppKit
import Core

// kelp-vm <machine folder>: runs one of Kelp's virtual machines for kelpd (Core/VMs.swift). The only program that holds
// the virtualization entitlement; it keeps running while its machine sleeps, so the next SSH connection wakes it.
//   kelp-vm --latest                    Apple's latest macOS restore image for this Mac, as JSON {url, build, version}
//   kelp-vm --install <folder> <ipsw>   installs macOS into a machine's folder; how far in its `creating` file
setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())

/// Runs `work` on the main actor with AppKit's run loop going (the installer and the restore image catalog answer on it).
func oneShot(_ work: @escaping @MainActor () async throws -> Void) -> Never {
    Task { @MainActor in
        do { try await work(); exit(0) } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
    }
    RunLoop.main.run()
    exit(0)
}

switch args.first {
case "--latest":
    oneShot {
        let l = try await MacGuest.latest()
        let json = try JSONSerialization.data(withJSONObject: ["url": l.url.absoluteString, "build": l.build, "version": l.version])
        print(String(decoding: json, as: UTF8.self))
    }
case "--install" where args.count == 3:
    let folder = URL(fileURLWithPath: args[1]), ipsw = URL(fileURLWithPath: args[2])
    oneShot {
        let m = try JSONDecoder().decode(VMMachine.self, from: Data(contentsOf: folder.appendingPathComponent("machine.json")))
        try await MacGuest.install(m, folder: folder, ipsw: ipsw) { f in
            try? Data("Installing macOS: \(Int(f * 100))%".utf8).write(to: folder.appendingPathComponent("creating"))
        }
    }
case .some(let path) where args.count == 1 && !path.hasPrefix("-"):
    let folder = URL(fileURLWithPath: path)
    let machine: VMMachine
    do { machine = try JSONDecoder().decode(VMMachine.self, from: Data(contentsOf: folder.appendingPathComponent("machine.json"))) }
    catch { log("can't read the machine: \(error)"); exit(1) }
    // An Android machine is the SDK's emulator, not Virtualization's: a runtime of its own, the same protocol.
    let android = machine.os == "android" ? AndroidRuntime(folder: folder, machine: machine) : nil
    let ios = machine.os == "ios" ? IOSRuntime(folder: folder, machine: machine) : nil
    let runtime: Runtime? = android == nil && ios == nil ? try? Runtime(folder: folder) : nil
    guard android != nil || ios != nil || runtime != nil else { log("can't start \(machine.name)"); exit(1) }
    android?.listen()
    ios?.listen()
    runtime?.listen()
    // AppKit's run loop, not dispatchMain() (that ends the main thread, and the main queue, the VM's and MainActor's, would
    // run elsewhere): a macOS machine's screen is a window.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
default:
    FileHandle.standardError.write(Data("usage: kelp-vm <machine folder> | --latest | --install <folder> <ipsw>\n".utf8))
    exit(2)
}
