import Core
import Foundation

/// A machine's screen read and driven for `kelp vm screenshot`, `click`, `ui`… (`VMScreen`, `VMUI`), woken first: a
/// macOS one's by its kelp-vm from the Mac's side (in `session`'s turn) and Kelp Guest inside, an Android one's through
/// adb, an iOS one's through Kelp's runner in its simulator. `args` as `kelp vm` takes them, the action first; what the
/// machine says back (`ui`'s controls) is the answer.
extension VMService {
    func screen(_ name: String, _ args: [String], session: String?) throws -> String {
        let machine = try ready(name)
        var words = ScreenWords(args)
        switch machine.kind {
        case .linux:
            throw RPCError.invalidParams(
                "\(name) is Linux: it has no screen. kelp vm run \(name) -- <command> runs commands in it.")
        case .macos: return try macScreen(machine, words, session: session)
        case .android: return try androidScreen(name, &words)
        case .ios: return try iosScreen(name, &words)
        }
    }

    /// Types into a macOS machine's screen; nil: its password, from the Keychain.
    func type(_ name: String, _ given: String?, session: String? = nil) throws {
        let text: String
        do { text = try given ?? Keychain.read("vm." + name) } catch {
            throw RPCError.internalError("\(name)'s password in the Keychain: \(error.localizedDescription)")
        }
        _ = try screen(name, ["type", text], session: session)   // nil: the user's (Type Password), no turn to wait for
    }

    private func macScreen(_ machine: VMMachine, _ words: ScreenWords, session: String?) throws -> String {
        let name = machine.name
        switch words.action {
        case "install", "launch", "open":
            throw RPCError.invalidParams(
                "\(words.action) is for Android and iOS machines: kelp vm run \(name) -- … does it on macOS.")
        case "ui", "press":   // the app's controls, through Kelp Guest's Accessibility inside
            return try overSSH(name, VMs.guestProgram + " " + words.all.map(IDE.shellWord).joined(separator: " "))
        case "type" where words.rest.joined(separator: " ").contains { VMs.usKey($0) == nil }:
            // No key for it: pasted instead, its clipboard set over SSH (without LANG, read as Mac Roman).
            _ = try overSSH(name, "LANG=en_US.UTF-8 pbcopy", stdin: Data(words.rest.joined(separator: " ").utf8))
            return try macScreen(machine, ScreenWords(["key", "cmd+v"]), session: session)
        default:
            try wake(machine)
            try check(ask(name, .init(op: .screen, args: words.all, session: session), wait: 110))
            return ""
        }
    }

    /// A command in the machine over its SSH (counted as use), in its home folder: what it printed.
    private func overSSH(_ name: String, _ command: String, stdin: Data? = nil) throws -> String {
        let to = try connect(name, cwd: nil)
        let out = try Subprocess.run(
            to.ssh + ["-T", "--", to.prefix + command], cwd: "/", env: ProcessInfo.processInfo.environment,
            stdin: stdin, timeLimit: 60)
        guard out.status == 0 else { throw RPCError.invalidParams(Self.said(out.stderr) ?? "\(name): it failed") }
        return Self.said(out.stdout) ?? ""
    }

    /// An Android machine's screen through adb: pixels of its screen for screenshots and taps alike.
    private func androidScreen(_ name: String, _ words: inout ScreenWords) throws -> String {
        let adb = try connect(name, cwd: nil).ssh   // adb -s <its emulator>, booted or woken first
        @discardableResult func run(_ a: [String]) throws -> Data {
            let out = try Subprocess.run(adb + a, cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 120)
            guard out.status == 0 else {
                throw RPCError.internalError(
                    "adb \(a.prefix(2).joined(separator: " ")): " + (Self.said(out.stderr) ?? ""))
            }
            return out.stdout
        }
        func ui() throws -> (text: String, centers: [String: (x: Int, y: Int)]) {
            let xml = String(decoding: try run(["exec-out", "uiautomator", "dump", "/dev/tty"]), as: UTF8.self)
            return AndroidSDK.ui(String(xml[..<(xml.range(of: "</hierarchy>")?.upperBound ?? xml.endIndex)]))
        }
        let right = words.has("--right"), double = words.has("--double")
        switch words.action {
        case "screenshot": try run(["exec-out", "screencap", "-p"]).write(to: URL(fileURLWithPath: try words.text(0)))
        case "click":
            let x = try words.number(0), y = try words.number(1)
            try run(right ? ["shell", "input", "swipe", x, y, x, y, "800"] : ["shell", "input", "tap", x, y])   // a long press
            if double { try run(["shell", "input", "tap", x, y]) }
        case "drag":
            try run(
                [
                    "shell", "input", "swipe", try words.number(0), try words.number(1), try words.number(2),
                    try words.number(3), "400"
                ])
        case "scroll":
            let dy = Int(try words.number(0)) ?? 0, x = words.rest.count > 2 ? try words.number(1) : "540"
            let y = Int(words.rest.count > 2 ? try words.number(2) : "1200") ?? 1200
            try run(["shell", "input", "swipe", x, "\(y)", x, "\(y + dy)", "300"])
        case "type": try run(["shell", "input", "text", AndroidSDK.inputText(words.rest.joined(separator: " "))])
        case "key":
            let key = (words.rest.first ?? "").lowercased()
            guard
                let code = AndroidSDK.keys[key].map(String.init) ?? (key.hasPrefix("keycode_") ? key.uppercased() : nil)
            else {
                throw RPCError.invalidParams(
                    "key: \(key)? home, back, enter, tab, delete, escape, up/down/left/right, appswitch, or KEYCODE_…")
            }
            try run(["shell", "input", "keyevent", code])
        case "ui": return try ui().text
        case "press":
            let target = words.rest.joined(separator: " "), screen = try ui()
            // By its text: the first such line's ref.
            let named = screen.text.split(separator: "\n").first { $0.contains("\"\(target)\"") }
            let ref =
                screen.centers[target] != nil
                ? target
                : named.flatMap { l in l.range(of: "[ref=").map { String(l[$0.upperBound...].prefix { $0 != "]" }) } }
            guard let ref, let center = screen.centers[ref] else {
                throw RPCError.invalidParams("No \(target) on its screen: kelp vm ui shows what's there.")
            }
            try run(["shell", "input", "tap", "\(center.x)", "\(center.y)"])
        case "launch":
            try run(["shell", "monkey", "-p", try words.text(0), "-c", "android.intent.category.LAUNCHER", "1"])
        case "open": try run(["shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", try words.text(0)])
        case "install": return Self.said(try run(["install", "-r", try words.text(0)])) ?? ""
        default:
            throw RPCError.invalidParams(
                "\(words.action) isn't for Android machines: "
                    + "screenshot, click, drag, scroll, type, key, ui, press, install, launch, open")
        }
        return ""
    }

    /// An iOS machine: simctl for apps and links, Kelp's runner in the simulator for its screen (in points: 393 × 852 on
    /// an iPhone 16, screenshots and taps alike).
    private func iosScreen(_ name: String, _ words: inout ScreenWords) throws -> String {
        let to = try connect(name, cwd: nil)
        guard let udid = to.device, let port = to.port else {
            throw RPCError.internalError("\(name)'s simulator isn't up")
        }
        let app = words.flag("--app"), right = words.has("--right"), double = words.has("--double")
        func runner(_ op: String, _ a: [String] = []) throws -> [String: Any] {
            var request: [String: Any] = ["op": op, "args": a]
            if let app { request["app"] = app }
            guard let reply = IOSRunnerClient.ask(port: port, request) else {
                throw RPCError.internalError("Kelp's runner didn't answer: kelp vm stop and start the machine.")
            }
            if let message = reply["error"] as? String { throw RPCError.invalidParams(message) }
            return reply
        }
        func text(_ op: String, _ a: [String] = []) throws -> String { try runner(op, a)["text"] as? String ?? "" }
        let simctl = to.ssh
        switch words.action {
        case "install": return try run(simctl + ["install", udid, try words.text(0)])
        case "launch":
            let id = try words.text(0)
            _ = try run(simctl + ["launch", udid, id])
            _ = IOSRunnerClient.ask(port: port, ["op": "app", "app": id])   // ui, type and press act on it from now on
            return ""
        case "open": return try run(simctl + ["openurl", udid, try words.text(0)])
        case "screenshot":
            guard let png = (try runner("screenshot")["png"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                throw RPCError.internalError("no screenshot")
            }
            try png.write(to: URL(fileURLWithPath: try words.text(0)))
            return ""
        case "click":
            return try text(
                "tap", Array(words.rest.prefix(2)) + (double ? ["--double"] : []) + (right ? ["--long"] : []))
        case "drag": return try text("swipe", Array(words.rest.prefix(4)))
        case "scroll":
            let dy = Double(words.rest.first ?? "") ?? 0, x = words.rest.count > 2 ? words.rest[1] : "196"
            let y = Double(words.rest.count > 2 ? words.rest[2] : "426") ?? 426
            return try text("swipe", [x, String(y), x, String(y + dy)])
        case "type": return try text("type", [words.rest.joined(separator: " ")])
        case "key": return try text("key", Array(words.rest.prefix(1)))
        case "ui": return try text("ui")
        case "press": return try text("press", [words.rest.joined(separator: " ")])
        default:
            throw RPCError.invalidParams(
                "\(words.action) isn't for iOS machines: "
                    + "screenshot, click, drag, scroll, type, key, ui, press, install, launch, open")
        }
    }

    /// What a program printed, trimmed; nil for nothing.
    static func said(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// `kelp vm`'s words for a screen: its action, then the rest, from which flags are taken as they're read.
struct ScreenWords {
    let action: String
    private(set) var rest: [String]
    /// As they came, the action first: what kelp-vm and Kelp Guest read for themselves.
    var all: [String] { [action] + rest }

    init(_ args: [String]) {
        action = args.first ?? ""
        rest = Array(args.dropFirst())
    }
    mutating func has(_ name: String) -> Bool {
        guard let index = rest.firstIndex(of: name) else { return false }
        rest.remove(at: index)
        return true
    }
    mutating func flag(_ name: String) -> String? {
        guard let index = rest.firstIndex(of: name), index + 1 < rest.count else { return nil }
        defer { rest.removeSubrange(index...index + 1) }
        return rest[index + 1]
    }
    /// The word at `index`, which must be there.
    func text(_ index: Int) throws -> String {
        guard rest.count > index else { throw RPCError.invalidParams("\(action): more words, see kelp vm --help") }
        return rest[index]
    }
    /// The number at `index`, as it was written.
    func number(_ index: Int) throws -> String {
        guard rest.count > index, Int(rest[index]) != nil else {
            throw RPCError.invalidParams("vm \(action): a number at \(index + 1)")
        }
        return rest[index]
    }
}
