import Core
import Foundation

extension Main {
    static let vmUsage = """
        vm list [--json] | create <name> [--image debian-13|macos|android|ios] [--file image.ipsw|disk.raw] [--cpus 2] [--memory 2] [--disk 32]
              | run <name> [--cwd dir | --home] [-- command…] | start|sleep|stop|show|delete <name>
              | screenshot <name> [file] | click <name> X Y [--right] [--double] | move|drag|scroll <name> … | type <name> TEXT
              | key <name> COMBO | ui <name> [--app NAME] | press <name> REF|TITLE   (macOS and Android machines: their screen)
              | install <name> APP.apk|App.app | launch <name> BUNDLE-ID | open <name> URL   (Android, iOS)
              | password <name>   (macOS: types its password into its screen, for the dialogs that ask)
              | set <name> [--cpus N] [--memory GB] [--disk GB]   (Linux, macOS; shut down; a disk only grows, Linux's)
        """

    /// `vm <action>`: Kelp's virtual machines (Core/VM/VMs.swift).
    static func vm(_ sub: String?, _ client: RPCClient) async throws {
        switch sub {
        case "list":
            let all = try await client.call(VMList())
            if has("--json") { return show(all) }
            guard !all.isEmpty else {
                return print("No machines. `kelp vm create debian` makes one (Debian 13, about 0.2 GB to download).")
            }
            for v in all { print(line(v)) }
        case "create":
            guard let name = args.first else {
                fail(
                    "vm create <name> [--image debian-13|macos|android|ios] [--file image.ipsw|disk.raw] [--cpus 2] [--memory 2] [--disk 32]"
                )
            }
            let request = VMCreate(
                name: name, image: flag("--image"), cpus: flag("--cpus").flatMap(Int.init),
                memory: flag("--memory").flatMap(Int.init), disk: flag("--disk").flatMap(Int.init),
                file: flag("--file").map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            func said(_ vmInfo: VMInfo) -> String? {
                vmInfo.step.map {
                    $0.text(vmInfo.detail) + (vmInfo.progress.map { String(format: ": %.0f%%", $0 * 100) } ?? "")
                }
            }
            var last = said(try await client.call(request))
            if let last { print(last) }
            while true {   // it answers at once; its progress is in the list
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard let info = try await client.call(VMList()).first(where: { $0.machine.name == name }) else {
                    fail("\(name) is gone")
                }
                if info.state == .error { fail("error: \(info.detail ?? "it failed")") }
                if info.state != .creating { return print(line(info)) }
                if let status = said(info), status != last {
                    print(status)
                    last = status
                }
            }
        case "screenshot", "click", "move", "drag", "scroll", "type", "key", "ui", "press", "install", "launch", "open":
            try await screen(sub ?? "", client)
        case "set":
            guard let name = args.first else { fail("vm set <name> [--cpus N] [--memory GB] [--disk GB]") }
            let request = VMConfigure(
                name: name, cpus: flag("--cpus").flatMap(Int.init), memory: flag("--memory").flatMap(Int.init),
                disk: flag("--disk").flatMap(Int.init))
            print(line(try await client.call(request)))
        case "password":
            guard let name = args.first else { fail("vm password <name>") }
            _ = try await client.call(VMType(name: name))
        case "start", "sleep", "stop", "show", "delete":
            guard let name = args.first, let action = VMControl.Action(rawValue: sub ?? "") else {
                fail("vm \(sub ?? "") <name>")
            }
            print(line(try await client.call(VMControl(name: name, action: action))))
        case "run":
            guard let name = args.first else { fail("vm run <name> [--cwd dir | --home] [-- command…]") }
            args.removeFirst()
            let home = has("--home")
            let cwd =
                home
                ? nil
                : URL(fileURLWithPath: flag("--cwd") ?? FileManager.default.currentDirectoryPath).standardizedFileURL
                    .path
            if args.first == "--" { args.removeFirst() }
            let os = try await client.call(VMList()).first(where: { $0.machine.name == name })?.machine.kind
            if os == .ios {   // a process in the simulator (no shell there to read a line)
                let to = try await client.call(VMConnect(name: name, cwd: nil))
                exec(to.ssh + ["spawn", to.device ?? ""] + args)
            }
            if os == .android {
                let adb = try await client.call(VMConnect(name: name, cwd: nil)).ssh   // Android's shell, through adb
                exec(adb + ["shell"] + (args.isEmpty ? [] : [args.joined(separator: " ")]))
            }
            let to = try await client.call(VMConnect(name: name, cwd: cwd))
            // A terminal on both ends gets one inside (an editor, htop); an agent's pipes don't. The session it comes from goes
            // with it: the machine's tab and the sidebar say whose command runs there.
            let tty = isatty(0) == 1 && isatty(1) == 1
            let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
            exec(
                to.ssh + [
                    tty ? "-t" : "-T", "--", to.prefix + VMs.command(args.joined(separator: " "), session: session)
                ])
        default: fail("usage: kelp " + vmUsage)
        }
    }

    /// Reads and drives a machine's screen through the daemon (`vm.screen`, `vm.ui`): a macOS machine's from the Mac's
    /// side and through Kelp Guest inside it, an Android one's through adb, an iOS one's through Kelp's runner. A
    /// screenshot goes to a file, and its path is printed.
    private static func screen(_ action: String, _ client: RPCClient) async throws {
        guard let name = args.first else { fail("vm \(action) <name> …") }
        args.removeFirst()
        if action == "ui" { return print(try await client.call(VMUI(name: name, app: flag("--app")))) }
        // Files as the daemon finds them, from its own folder.
        func file(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
        switch action {
        case "screenshot":
            let out = file(
                args.first ?? NSTemporaryDirectory() + "kelp-\(name)-\(Int(Date().timeIntervalSince1970)).png")
            _ = try await client.call(VMScreen(name: name, args: ["screenshot", out], session: session))
            print(out)
        case "type":
            _ = try await client.call(
                VMScreen(name: name, args: ["type", args.joined(separator: " ")], session: session))
        case "install":
            guard let app = args.first else { fail("vm install <name> APP.apk|App.app") }
            _ = try await client.call(VMScreen(name: name, args: ["install", file(app)], session: session))
        default:
            _ = try await client.call(VMScreen(name: name, args: [action] + args, session: session))
            if action == "press" { print("pressed") }
        }
    }

    private static func line(_ vmInfo: VMInfo) -> String {
        let image = VMImage.named(vmInfo.machine.image)?.title ?? vmInfo.machine.image
        var parts = [
            vmInfo.machine.name.padding(toLength: 10, withPad: " ", startingAt: 0),
            image.padding(toLength: 12, withPad: " ", startingAt: 0),
            vmInfo.state.rawValue
        ]
        if let cpu = vmInfo.cpu { parts.append(String(format: "%.0f%% CPU", cpu)) }
        if let memory = vmInfo.memoryMiB { parts.append(String(format: "%.1f GB", Double(memory) / 1024)) }
        if vmInfo.state == .sleeping || vmInfo.state == .off, let disk = vmInfo.diskMiB {
            parts.append(String(format: "%.1f GB on disk", Double(disk) / 1024))
        }
        if let connections = vmInfo.connections, connections > 0 { parts.append("\(connections) open") }
        if vmInfo.state == .sleeping {
            parts.append(vmInfo.machine.kind == .linux ? "wakes in under a second" : "wakes in a few seconds")
        }
        if let step = vmInfo.step {
            parts.append(
                step.text(vmInfo.detail) + (vmInfo.progress.map { String(format: ": %.0f%%", $0 * 100) } ?? ""))
        } else if let detail = vmInfo.detail {
            parts.append(detail)
        }
        return parts.joined(separator: "  ")
    }

    private static func exec(_ argv: [String]) -> Never {
        let cArgs = argv.map { strdup($0) } + [nil]
        execv(argv[0], cArgs)
        fail("kelp: \(argv[0]): \(String(cString: strerror(errno)))")
    }
}
