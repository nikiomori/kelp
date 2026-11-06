import Foundation
import Core

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

    /// `vm <action>`: Kelp's virtual machines (Core/VMs.swift).
    static func vm(_ sub: String?, _ c: RPCClient) async throws {
        switch sub {
        case "list":
            let all = try await c.call(VMList())
            if has("--json") { return show(all) }
            guard !all.isEmpty else { return print("No machines. `kelp vm create debian` makes one (Debian 13, about 0.2 GB to download).") }
            for v in all { print(line(v)) }
        case "create":
            guard let name = args.first else { fail("vm create <name> [--image debian-13|macos|android|ios] [--file image.ipsw|disk.raw] [--cpus 2] [--memory 2] [--disk 32]") }
            let r = VMCreate(name: name, image: flag("--image"), cpus: flag("--cpus").flatMap(Int.init),
                             memory: flag("--memory").flatMap(Int.init), disk: flag("--disk").flatMap(Int.init),
                             file: flag("--file").map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            func said(_ v: VMInfo) -> String? { v.step.map { $0.text(v.detail) + (v.progress.map { String(format: ": %.0f%%", $0 * 100) } ?? "") } }
            var last = said(try await c.call(r))
            if let last { print(last) }
            while true {   // it answers at once; its progress is in the list
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard let v = try await c.call(VMList()).first(where: { $0.machine.name == name }) else { fail("\(name) is gone") }
                if v.state == .error { fail("error: \(v.detail ?? "it failed")") }
                if v.state != .creating { return print(line(v)) }
                if let s = said(v), s != last { print(s); last = s }
            }
        case "screenshot", "click", "move", "drag", "scroll", "type", "key", "ui", "press", "install", "launch", "open":
            try await screen(sub ?? "", c)
        case "set":
            guard let name = args.first else { fail("vm set <name> [--cpus N] [--memory GB] [--disk GB]") }
            let r = VMConfigure(name: name, cpus: flag("--cpus").flatMap(Int.init), memory: flag("--memory").flatMap(Int.init),
                                disk: flag("--disk").flatMap(Int.init))
            print(line(try await c.call(r)))
        case "password":
            guard let name = args.first else { fail("vm password <name>") }
            _ = try await c.call(VMType(name: name))
        case "start", "sleep", "stop", "show", "delete":
            guard let name = args.first, let action = VMControl.Action(rawValue: sub ?? "") else { fail("vm \(sub ?? "") <name>") }
            print(line(try await c.call(VMControl(name: name, action: action))))
        case "run":
            guard let name = args.first else { fail("vm run <name> [--cwd dir | --home] [-- command…]") }
            args.removeFirst()
            let home = has("--home")
            let cwd = home ? nil : URL(fileURLWithPath: flag("--cwd") ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
            if args.first == "--" { args.removeFirst() }
            let os = try await c.call(VMList()).first(where: { $0.machine.name == name })?.machine.os
            if os == "ios" {   // a process in the simulator (no shell there to read a line)
                let to = try await c.call(VMConnect(name: name, cwd: nil))
                exec(to.ssh + ["spawn", to.device ?? ""] + args)
            }
            if os == "android" {
                let adb = try await c.call(VMConnect(name: name, cwd: nil)).ssh   // Android's shell, through adb
                exec(adb + ["shell"] + (args.isEmpty ? [] : [args.joined(separator: " ")]))
            }
            let to = try await c.call(VMConnect(name: name, cwd: cwd))
            // A terminal on both ends gets one inside (an editor, htop); an agent's pipes don't. The session it comes from goes
            // with it: the machine's tab and the sidebar say whose command runs there.
            let tty = isatty(0) == 1 && isatty(1) == 1
            let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
            exec(to.ssh + [tty ? "-t" : "-T", "--", to.prefix + VMs.command(args.joined(separator: " "), session: session)])
        default: fail("usage: kelp " + vmUsage)
        }
    }

    /// A machine's screen. macOS: read and driven from the Mac's side (`vm.screen`), a screenshot to a file (its path
    /// printed); its controls by name through Kelp Guest inside.
    private static func screen(_ action: String, _ c: RPCClient) async throws {
        guard let name = args.first else { fail("vm \(action) <name> …") }
        args.removeFirst()
        guard let v = try await c.call(VMList()).first(where: { $0.machine.name == name }) else { fail("No machine called \(name).") }
        guard v.machine.os != "linux" else { fail("\(name) is Linux: it has no screen. kelp vm run \(name) -- <command> runs commands in it.") }
        if v.machine.os == "android" { return try await android(action, adb: try await c.call(VMConnect(name: name, cwd: nil)).ssh) }
        if v.machine.os == "ios" { return try await ios(action, try await c.call(VMConnect(name: name, cwd: nil))) }
        guard !["install", "launch", "open"].contains(action) else {
            fail("\(action) is for Android and iOS machines: kelp vm run \(name) -- … does it on macOS.")
        }
        let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
        if action == "ui" || action == "press" {   // the app's controls, through Kelp Guest's Accessibility inside
            let to = try await c.call(VMConnect(name: name, cwd: nil))
            let remote = VMs.guestProgram + " " + ([action] + args + ["--session", session ?? "-"]).map(VMs.shellQuoted).joined(separator: " ")
            exec(to.ssh + ["-T", "--", to.prefix + remote])
        }
        if action == "screenshot" {
            let out = URL(fileURLWithPath: args.first ?? NSTemporaryDirectory() + "kelp-\(name)-\(Int(Date().timeIntervalSince1970)).png").standardizedFileURL
            _ = try await c.call(VMScreen(name: name, args: ["screenshot", out.path], session: session))
            return print(out.path)
        }
        let text = args.joined(separator: " ")
        if action == "type", text.contains(where: { VMs.usKey($0) == nil }) {   // no key for it: pasted instead
            let to = try await c.call(VMConnect(name: name, cwd: nil))
            let copied = Process()
            copied.executableURL = URL(fileURLWithPath: to.ssh[0])
            copied.arguments = Array(to.ssh.dropFirst()) + ["-T", "--", to.prefix + "LANG=en_US.UTF-8 pbcopy"]   // without it, read as Mac Roman
            let input = Pipe()
            copied.standardInput = input
            try copied.run()
            input.fileHandleForWriting.write(Data(text.utf8))
            try input.fileHandleForWriting.close()
            copied.waitUntilExit()
            guard copied.terminationStatus == 0 else { fail("couldn't put the text on \(name)'s clipboard") }
            _ = try await c.call(VMScreen(name: name, args: ["key", "cmd+v"], session: session))
            return
        }
        _ = try await c.call(VMScreen(name: name, args: action == "type" ? ["type", text] : [action] + args, session: session))
    }

    /// An Android machine's screen through adb: pixels of its screen for screenshots and taps alike.
    private static func android(_ action: String, adb: [String]) async throws {
        func run(_ a: [String]) -> Data {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: adb[0])
            p.arguments = Array(adb.dropFirst()) + a
            p.standardOutput = out
            do { try p.run() } catch { fail("adb: \(error)") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { exit(p.terminationStatus) }
            return data
        }
        func int(_ i: Int) -> String {
            guard args.count > i, Int(args[i]) != nil else { fail("vm \(action): a number at \(i + 1)") }
            return args[i]
        }
        func ui() -> (text: String, centers: [String: (x: Int, y: Int)]) {
            let xml = String(decoding: run(["exec-out", "uiautomator", "dump", "/dev/tty"]), as: UTF8.self)
            return AndroidSDK.ui(String(xml[..<(xml.range(of: "</hierarchy>")?.upperBound ?? xml.endIndex)]))
        }
        switch action {
        case "screenshot":
            let out = URL(fileURLWithPath: args.first ?? NSTemporaryDirectory() + "kelp-android-\(Int(Date().timeIntervalSince1970)).png").standardizedFileURL
            try run(["exec-out", "screencap", "-p"]).write(to: out)
            print(out.path)
        case "click":
            let tap = ["shell", "input", "tap", int(0), int(1)]
            _ = run(has("--right") ? ["shell", "input", "swipe", args[0], args[1], args[0], args[1], "800"] : tap)   // a long press
            if has("--double") { _ = run(tap) }
        case "drag": _ = run(["shell", "input", "swipe", int(0), int(1), int(2), int(3), "400"])
        case "scroll":
            let dy = Int(int(0)) ?? 0, x = args.count > 2 ? int(1) : "540", y = Int(args.count > 2 ? int(2) : "1200") ?? 1200
            _ = run(["shell", "input", "swipe", x, "\(y)", x, "\(y + dy)", "300"])
        case "type": _ = run(["shell", "input", "text", AndroidSDK.inputText(args.joined(separator: " "))])
        case "key":
            let name = (args.first ?? "").lowercased()
            guard let code = AndroidSDK.keys[name].map(String.init) ?? (name.hasPrefix("keycode_") ? name.uppercased() : nil) else {
                fail("key: \(name)? home, back, enter, tab, delete, escape, up/down/left/right, appswitch, or KEYCODE_…")
            }
            _ = run(["shell", "input", "keyevent", code])
        case "ui": print(ui().text)
        case "press":
            let target = args.joined(separator: " "), screen = ui()
            let named = screen.text.split(separator: "\n").first { $0.contains("\"\(target)\"") }   // by its text: the first such line's ref
            let ref = screen.centers[target] != nil ? target
                : named.flatMap { l in l.range(of: "[ref=").map { String(l[$0.upperBound...].prefix { $0 != "]" }) } }
            guard let ref, let c = screen.centers[ref] else { fail("No \(target) on its screen: kelp vm ui shows what's there.") }
            _ = run(["shell", "input", "tap", "\(c.x)", "\(c.y)"])
            print("pressed")
        case "launch":
            guard let id = args.first else { fail("vm launch <name> PACKAGE") }
            _ = run(["shell", "monkey", "-p", id, "-c", "android.intent.category.LAUNCHER", "1"])
        case "open":
            guard let url = args.first else { fail("vm open <name> URL") }
            _ = run(["shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url])
        case "install":
            guard let apk = args.first else { fail("vm install <name> APP.apk") }
            FileHandle.standardOutput.write(run(["install", "-r", URL(fileURLWithPath: apk).standardizedFileURL.path]))
        default: fail("\(action) isn't for Android machines: screenshot, click, drag, scroll, type, key, ui, press, install, launch, open")
        }
    }

    /// An iOS machine: simctl for apps and links, Kelp's runner in the simulator for its screen (in points: 393 × 852 on an
    /// iPhone 16, screenshots and taps alike).
    private static func ios(_ action: String, _ to: VMConnection) async throws {
        guard let udid = to.device, let port = to.port else { fail("its simulator isn't up") }
        func simctl(_ a: [String]) -> Never { exec(to.ssh + a) }
        func runner(_ op: String, _ a: [String] = []) -> [String: Any] {
            var request: [String: Any] = ["op": op, "args": a]
            if let app = flag("--app") { request["app"] = app }
            guard let r = IOSRunnerClient.ask(port: port, request) else { fail("Kelp's runner didn't answer: kelp vm stop and start the machine.") }
            if let e = r["error"] as? String { fail(e) }
            return r
        }
        func text(_ op: String, _ a: [String] = []) { print(runner(op, a)["text"] as? String ?? "") }
        switch action {
        case "install":
            guard let app = args.first else { fail("vm install <name> App.app") }
            simctl(["install", udid, URL(fileURLWithPath: app).standardizedFileURL.path])
        case "launch":
            guard let id = args.first else { fail("vm launch <name> BUNDLE-ID") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: to.ssh[0]); p.arguments = Array(to.ssh.dropFirst()) + ["launch", udid, id]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { exit(p.terminationStatus) }
            _ = IOSRunnerClient.ask(port: port, ["op": "app", "app": id])   // ui, type and press act on it from now on
        case "open":
            guard let url = args.first else { fail("vm open <name> URL") }
            simctl(["openurl", udid, url])
        case "screenshot":
            let out = URL(fileURLWithPath: args.first ?? NSTemporaryDirectory() + "kelp-ios-\(Int(Date().timeIntervalSince1970)).png").standardizedFileURL
            guard let png = (runner("screenshot")["png"] as? String).flatMap({ Data(base64Encoded: $0) }) else { fail("no screenshot") }
            try png.write(to: out)
            print(out.path)
        case "click":
            let a = Array(args.prefix(2)) + (has("--double") ? ["--double"] : []) + (has("--right") ? ["--long"] : [])
            text("tap", a)
        case "drag": text("swipe", Array(args.prefix(4)))
        case "scroll":
            let dy = Double(args.first ?? "") ?? 0, x = args.count > 2 ? args[1] : "196", y = Double(args.count > 2 ? args[2] : "426") ?? 426
            text("swipe", [x, String(y), x, String(y + dy)])
        case "type": text("type", [args.joined(separator: " ")])
        case "key": text("key", Array(args.prefix(1)))
        case "ui": text("ui")
        case "press": text("press", [args.joined(separator: " ")])
        default: fail("\(action) isn't for iOS machines: screenshot, click, drag, scroll, type, key, ui, press, install, launch, open")
        }
    }

    private static func line(_ v: VMInfo) -> String {
        let image = VMImage.named(v.machine.image)?.title ?? v.machine.image
        var parts = [v.machine.name.padding(toLength: 10, withPad: " ", startingAt: 0), image.padding(toLength: 12, withPad: " ", startingAt: 0),
                     v.state.rawValue]
        if let m = v.memoryMiB { parts.append(String(format: "%.1f GB", Double(m) / 1024)) }
        if let n = v.connections, n > 0 { parts.append("\(n) open") }
        if v.state == .sleeping { parts.append(v.machine.os == "linux" ? "wakes in under a second" : "wakes in a few seconds") }
        if let s = v.step { parts.append(s.text(v.detail) + (v.progress.map { String(format: ": %.0f%%", $0 * 100) } ?? "")) }
        else if let d = v.detail { parts.append(d) }
        return parts.joined(separator: "  ")
    }

    private static func exec(_ argv: [String]) -> Never {
        let c = argv.map { strdup($0) } + [nil]
        execv(argv[0], c)
        fail("kelp: \(argv[0]): \(String(cString: strerror(errno)))")
    }
}
