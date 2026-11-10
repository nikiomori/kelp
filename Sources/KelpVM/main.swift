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
        do {
            try await work()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
    exit(0)
}

switch args.first {
case "--latest":
    oneShot {
        let latest = try await MacGuest.latest()
        let json = try JSONSerialization.data(withJSONObject: [
            "url": latest.url.absoluteString, "build": latest.build, "version": latest.version
        ])
        print(String(decoding: json, as: UTF8.self))
    }
case "--install" where args.count == 3:
    let folder = URL(fileURLWithPath: args[1]), ipsw = URL(fileURLWithPath: args[2])
    oneShot {
        let machine = try JSONDecoder().decode(
            VMMachine.self, from: Data(contentsOf: folder.appendingPathComponent("machine.json")))
        try await MacGuest.install(machine, folder: folder, ipsw: ipsw) { fraction in
            let at = VMMaking(
                step: .installing, progress: fraction,
                detail: Data(contentsIfAny: folder.appendingPathComponent("creating"))
                    .flatMap { try? JSONDecoder().decode(VMMaking.self, from: $0) }?.detail)
            do { try at.data.write(to: folder.appendingPathComponent("creating"), options: .atomic) } catch {
                log("can't say how far the install is: \(error)")
            }
        }
    }
case .some(let path) where args.count == 1 && !path.hasPrefix("-"):
    let folder = URL(fileURLWithPath: path)
    // One kelp-vm per machine, holding this while it runs (kelpd tells a running one by it, `VMService.alive`), taken
    // before the machine is read: a new size is written under it (`configure`), and is what this one starts with. Tried
    // for half a second: a size being written, or kelpd's look at it, holds it a moment.
    guard Lifecycle.hold(folder) != nil else {
        log("another kelp-vm runs \(folder.lastPathComponent)")
        exit(0)
    }
    let machine: VMMachine
    do {
        machine = try JSONDecoder().decode(
            VMMachine.self, from: Data(contentsOf: folder.appendingPathComponent("machine.json")))
    } catch {
        log("can't read the machine: \(error)")
        exit(1)
    }
    // An Android machine is the SDK's emulator, not Virtualization's: a runtime of its own, the same protocol.
    let android = machine.kind == .android ? AndroidRuntime(folder: folder, machine: machine) : nil
    let ios = machine.kind == .ios ? IOSRuntime(folder: folder, machine: machine) : nil
    var runtime: Runtime?
    if android == nil, ios == nil {
        do { runtime = try Runtime(folder: folder) } catch { log("can't make the machine: \(error)") }
    }
    guard android != nil || ios != nil || runtime != nil else {
        log("can't start \(machine.name)")
        exit(1)
    }
    android?.listen()
    ios?.listen()
    runtime?.listen()
    // AppKit's run loop, not dispatchMain() (that ends the main thread, and the main queue, the VM's and MainActor's, would
    // run elsewhere): a macOS machine's screen is a window.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
default:
    FileHandle.standardError.write(
        Data("usage: kelp-vm <machine folder> | --latest | --install <folder> <ipsw>\n".utf8))
    exit(2)
}
