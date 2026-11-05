import Foundation
import Core

extension Main {
    static let vmUsage = """
    vm list [--json] | create <name> [--image debian-13] [--cpus 2] [--memory 2] [--disk 32]
          | run <name> [--cwd dir | --home] [-- command…] | start|sleep|stop <name>
    """

    /// `vm <action>`: Kelp's virtual machines (Core/VMs.swift).
    static func vm(_ sub: String?, _ c: RPCClient) async throws {
        switch sub {
        case "list":
            let all = try await c.call(VMList())
            if has("--json") { return show(all) }
            guard !all.isEmpty else { return print("No machines. `kelp vm create debian` makes one (Debian 13, about 0.2 GB to download).") }
            for v in all { print(line(v)) }
        case "create":
            guard let name = args.first else { fail("vm create <name> [--image debian-13] [--cpus 2] [--memory 2] [--disk 32]") }
            let r = VMCreate(name: name, image: flag("--image"), cpus: flag("--cpus").flatMap(Int.init),
                             memory: flag("--memory").flatMap(Int.init), disk: flag("--disk").flatMap(Int.init))
            var last = try await c.call(r).detail
            if let last { print(last) }
            while true {   // it answers at once; its progress is in the list
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard let v = try await c.call(VMList()).first(where: { $0.machine.name == name }) else { fail("\(name) is gone") }
                if v.state == .error { fail("error: \(v.detail ?? "it failed")") }
                if v.state != .creating { return print(line(v)) }
                if v.detail != last, let d = v.detail { print(d); last = d }
            }
        case "start", "sleep", "stop":
            guard let name = args.first, let action = VMControl.Action(rawValue: sub ?? "") else { fail("vm \(sub ?? "") <name>") }
            print(line(try await c.call(VMControl(name: name, action: action))))
        case "run":
            guard let name = args.first else { fail("vm run <name> [--cwd dir | --home] [-- command…]") }
            args.removeFirst()
            let home = has("--home")
            let cwd = home ? nil : URL(fileURLWithPath: flag("--cwd") ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
            if args.first == "--" { args.removeFirst() }
            let to = try await c.call(VMConnect(name: name, cwd: cwd))
            // A terminal on both ends gets one inside (an editor, htop); an agent's pipes don't. The session it comes from goes
            // with it: the machine's tab and the sidebar say whose command runs there.
            let tty = isatty(0) == 1 && isatty(1) == 1
            let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
            exec(to.ssh + [tty ? "-t" : "-T", "--", to.prefix + VMs.command(args.joined(separator: " "), session: session)])
        default: fail("usage: kelp " + vmUsage)
        }
    }

    private static func line(_ v: VMInfo) -> String {
        let image = VMImage.named(v.machine.image)?.title ?? v.machine.image
        var parts = [v.machine.name.padding(toLength: 10, withPad: " ", startingAt: 0), image.padding(toLength: 12, withPad: " ", startingAt: 0),
                     v.state.rawValue]
        if let m = v.memoryMiB { parts.append(String(format: "%.1f GB", Double(m) / 1024)) }
        if let n = v.connections, n > 0 { parts.append("\(n) open") }
        if v.state == .sleeping { parts.append("wakes in under a second") }
        if let d = v.detail { parts.append(d) }
        return parts.joined(separator: "  ")
    }

    private static func exec(_ argv: [String]) -> Never {
        let c = argv.map { strdup($0) } + [nil]
        execv(argv[0], c)
        fail("kelp: \(argv[0]): \(String(cString: strerror(errno)))")
    }
}
