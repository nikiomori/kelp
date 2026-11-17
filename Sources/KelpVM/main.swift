import AppKit
import Core

// kelp-vm <machine folder> runs one of Kelp's virtual machines for kelpd (Core/VM/VMs.swift). It is the only program
// that holds the virtualization entitlement. It keeps running while its machine sleeps, so the next SSH connection
// wakes the machine.
//   kelp-vm --latest                    Apple's latest macOS restore image for this Mac, as JSON {url, build, version}
//   kelp-vm --install <folder> <ipsw>   installs macOS into a machine's folder, writing its progress to `creating`
setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())

/// Runs `work` on the main actor with AppKit's run loop going, because the installer and the restore image catalog
/// answer on that run loop.
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
            VMMachine.self, from: Data(contentsOf: VMFolder(folder).machine))
        try await MacGuest.install(machine, folder: folder, ipsw: ipsw) { fraction in
            let at = VMMaking(
                step: .installing, progress: fraction,
                detail: Data(contentsIfAny: VMFolder(folder).creating)
                    .flatMap { try? JSONDecoder().decode(VMMaking.self, from: $0) }?.detail)
            do { try at.data.write(to: VMFolder(folder).creating, options: .atomic) } catch {
                log("can't say how far the install is: \(error)")
            }
        }
    }
case .some(let path) where args.count == 1 && !path.hasPrefix("-"):
    let folder = URL(fileURLWithPath: path)
    // Only one kelp-vm runs per machine, and it holds this lock while it runs. kelpd tells a running kelp-vm by the
    // lock (`VMService.alive`). The lock is taken before the machine is read, because `configure` writes a new size
    // under it, so this kelp-vm starts with that size. Taking it is tried for half a second, because a size being
    // written, or kelpd checking the lock, holds it for a moment.
    guard Lifecycle.hold(folder) != nil else {
        log("another kelp-vm runs \(folder.lastPathComponent)")
        exit(0)
    }
    Lifecycle.remember(getpid(), in: folder, as: VMFolder.helperNote)
    let machine: VMMachine
    do {
        machine = try JSONDecoder().decode(
            VMMachine.self, from: Data(contentsOf: VMFolder(folder).machine))
    } catch {
        log("can't read the machine: \(error)")
        exit(1)
    }
    // An Android machine runs in the SDK's emulator and an iOS machine in a simulator, not in Virtualization. Each has
    // a runtime of its own, and all the runtimes share one protocol (`MachineRuntime`).
    let runtime: any MachineRuntime
    switch machine.kind {
    case .android: runtime = AndroidRuntime(folder: folder, machine: machine)
    case .ios: runtime = IOSRuntime(folder: folder, machine: machine)
    default:
        do { runtime = try Runtime(folder: folder) } catch {
            log("can't make the machine: \(error)")
            log("can't start \(machine.name)")
            exit(1)
        }
    }
    runtime.listen()
    // This runs AppKit's run loop rather than dispatchMain(), because dispatchMain() ends the main thread and the main
    // queue (which the VM and MainActor use) would then run elsewhere. A macOS machine's screen is a window, so it
    // needs AppKit too.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
default:
    FileHandle.standardError.write(
        Data("usage: kelp-vm <machine folder> | --latest | --install <folder> <ipsw>\n".utf8))
    exit(2)
}
