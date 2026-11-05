import AppKit
import ApplicationServices
import ScreenCaptureKit

// Kelp Guest: inside a Kelp macOS machine, what agents see and do on its screen. Started at login (a LaunchAgent), it holds
// Screen Recording and Accessibility, granted once in the machine; run over SSH with arguments, the same program asks it:
//   KelpGuest screenshot                  PNG on stdout, in screen points (1280 × 800): the coordinates clicks take
//   KelpGuest click X Y [--right] [--double] | move X Y | drag X Y X2 Y2 | scroll DY [X Y]
//   KelpGuest type TEXT | key COMBO       (cmd+space, return, shift+tab…)
//   KelpGuest ui [--app NAME]             the front app's controls, a line each, with refs: "- button "Save" [ref=e12]"
//   KelpGuest press REF|TITLE             presses a control through Accessibility: no pointer, no screen turn
//   KelpGuest status                      its permissions and who has the screen
// The screen is one: clicks, keys and scrolls take turns (`--session` says whose); reading and `press` don't.

setvbuf(stdout, nil, _IOLBF, 0)
let socketPath = NSTemporaryDirectory() + "kelp-guest.sock"
let argv = Array(CommandLine.arguments.dropFirst())

if argv.isEmpty {
    MainActor.assumeIsolated {   // top-level code runs on the main thread
        let server = Server()
        server.start()
        NSApplication.shared.setActivationPolicy(.accessory)
        withExtendedLifetime(server) { NSApplication.shared.run() }
    }
} else {
    exit(Client.ask(argv))
}

/// The CLI side: one request line to the running app, its answer out.
enum Client {
    static func ask(_ argv: [String]) -> Int32 {
        var args = argv, session = "-"
        if let i = args.firstIndex(of: "--session"), i + 1 < args.count { session = args[i + 1]; args.removeSubrange(i...i + 1) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = unixAddress(socketPath)
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else {
            FileHandle.standardError.write(Data("Kelp Guest isn't running: open the machine's window and sign in.\n".utf8))
            return 3
        }
        let request = (try? JSONSerialization.data(withJSONObject: ["args": args, "session": session])) ?? Data()
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        _ = write(fd, "\n", 1)
        var reply = Data(), buf = [UInt8](repeating: 0, count: 1 << 16)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; reply.append(contentsOf: buf[0..<n]) }
        close(fd)
        guard let r = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return 1 }
        if let e = r["error"] as? String { FileHandle.standardError.write(Data((e + "\n").utf8)); return 1 }
        if let png = (r["png"] as? String).flatMap({ Data(base64Encoded: $0) }) { FileHandle.standardOutput.write(png) }
        if let text = r["text"] as? String { print(text) }
        return 0
    }
}

/// The app side: answers on a Unix socket, one request per connection, on the main thread.
@MainActor
final class Server {
    private var source: DispatchSourceRead?
    /// Whose turn the screen is: a session and when its turn ends (20 s after its last action).
    private var holder: (session: String, until: Date)?
    private var refs: [String: AXUIElement] = [:]

    func start() {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = unixAddress(socketPath)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        chmod(socketPath, 0o600)
        listen(fd, 16)
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            MainActor.assumeIsolated { self?.serve(c) }   // a read source on the main queue
        }
        s.resume()
        source = s
        // Asked once at the start, so the machine's window shows the two switches to turn on.
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
    }

    private func serve(_ fd: Int32) {
        var line = Data(), byte: UInt8 = 0
        while line.count < 1 << 20, read(fd, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
        let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let args = req?["args"] as? [String] ?? [], session = req?["session"] as? String ?? "-"
        Task {
            var reply: [String: Any]
            do { reply = try await handle(args, session: session) } catch { reply = ["error": "\(error)"] }
            let d = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
            d.withUnsafeBytes { p in
                guard let base = p.baseAddress else { return }
                var off = 0
                while off < p.count { let n = write(fd, base + off, p.count - off); if n <= 0 { break }; off += n }
            }
            close(fd)
        }
    }

    private func handle(_ a: [String], session: String) async throws -> [String: Any] {
        let op = a.first ?? ""
        func num(_ i: Int) throws -> Double {
            guard a.count > i, let v = Double(a[i]) else { throw Failure("\(op): a number at \(i)") }
            return v
        }
        switch op {
        case "status":
            let turn = holder.map { $0.until > Date() ? "screen: \($0.session)" : "screen: free" } ?? "screen: free"
            let screen = CGPreflightScreenCaptureAccess() ? "on" : "off", ax = AXIsProcessTrusted() ? "on" : "off"
            return ["text": "screen recording: \(screen)\naccessibility: \(ax)\n\(turn)"]
        case "screenshot": return ["png": try await screenshot().base64EncodedString()]
        case "ui": return ["text": try ui(app: a.firstIndex(of: "--app").flatMap { a.count > $0 + 1 ? a[$0 + 1] : nil })]
        case "press": return ["text": try press(a.dropFirst().joined(separator: " "))]
        default: break
        }
        guard AXIsProcessTrusted() else { throw Failure("Allow Kelp Guest in the machine's System Settings › Privacy & Security › Accessibility.") }
        try await takeTurn(session)
        switch op {
        case "click":
            let p = CGPoint(x: try num(1), y: try num(2))
            let right = a.contains("--right"), times = a.contains("--double") ? 2 : 1
            for n in 1...times { post(mouse: p, right: right, count: n) }
        case "move": move(to: CGPoint(x: try num(1), y: try num(2)))
        case "drag": drag(from: CGPoint(x: try num(1), y: try num(2)), to: CGPoint(x: try num(3), y: try num(4)))
        case "scroll":
            if a.count >= 4 { move(to: CGPoint(x: try num(2), y: try num(3))) }
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(try num(1)), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        case "type": type(a.dropFirst().joined(separator: " "))
        case "key": try key(a.count > 1 ? a[1] : "")
        default: throw Failure("unknown: \(op). screenshot, click, move, drag, scroll, type, key, ui, press, status")
        }
        try await Task.sleep(nanoseconds: 150_000_000)   // let the screen catch up before the next look
        return ["text": "ok"]
    }

    /// Waits up to a minute for the screen: another session's turn ends 20 s after its last action.
    private func takeTurn(_ session: String) async throws {
        let end = Date().addingTimeInterval(60)
        while let h = holder, h.session != session, h.until > Date() {
            guard Date() < end else { throw Failure("The screen is \(h.session)'s now; try again in a moment, or use ui and press, which don't need it.") }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        holder = (session, Date().addingTimeInterval(20))
    }

    private func screenshot() async throws -> Data {
        guard CGPreflightScreenCaptureAccess() else {
            throw Failure("Allow Kelp Guest in the machine's System Settings › Privacy & Security › Screen Recording.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Failure("no display") }
        let config = SCStreamConfiguration()
        config.width = display.width; config.height = display.height   // points: what clicks take
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure("can't encode the screenshot") }
        return png
    }

    private func post(mouse p: CGPoint, right: Bool, count: Int) {
        let (down, up): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for t in [down, up] {
            let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: right ? .right : .left)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            e?.post(tap: .cghidEventTap)
        }
    }

    private func move(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func drag(from a: CGPoint, to b: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)?.post(tap: .cghidEventTap)
        for i in 1...10 {
            let t = CGFloat(i) / 10
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(10_000)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Unicode text as typed: no keyboard layout in the way.
    private func type(_ text: String) {
        for chunk in Array(text.utf16).chunked(16) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                e?.post(tap: .cghidEventTap)
            }
            usleep(5_000)
        }
    }

    static let keys: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96
    ]

    private func key(_ combo: String) throws {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.last, let code = Self.keys[name] else { throw Failure("key: \(combo)? e.g. cmd+space, return, shift+tab") }
        var flags: CGEventFlags = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw Failure("key: \(m)? cmd, shift, alt, ctrl")
            }
        }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Accessibility

    /// The front app's window controls, a line each, indented by depth, with a ref to press: "- button "Save" [ref=e12]".
    private func ui(app name: String?) throws -> String {
        guard AXIsProcessTrusted() else { throw Failure("Allow Kelp Guest in the machine's System Settings › Privacy & Security › Accessibility.") }
        let running = name.flatMap { n in NSWorkspace.shared.runningApplications.first { $0.localizedName?.caseInsensitiveCompare(n) == .orderedSame } }
            ?? NSWorkspace.shared.frontmostApplication
        guard let app = running else { throw Failure("No app \(name ?? "in front").") }
        refs = [:]
        var lines = ["\(app.localizedName ?? "?") (pid \(app.processIdentifier))"], count = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 14, count < 400 else { return }
            let role = attr(e, kAXRoleAttribute) ?? ""
            let title = attr(e, kAXTitleAttribute) ?? attr(e, kAXDescriptionAttribute) ?? attr(e, kAXValueAttribute).map { String($0.prefix(60)) } ?? ""
            let interesting = !title.isEmpty || ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXPopUpButton", "AXMenuItem", "AXLink"].contains(role)
            var next = depth
            if interesting, role != "AXApplication" {
                count += 1
                let ref = "e\(count)"
                refs[ref] = e
                lines.append(String(repeating: "  ", count: depth) + "- \(role.dropFirst(2).lowercased()) \"\(title)\" [ref=\(ref)]" + frame(e))
                next = depth + 1
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
                for c in list { walk(c, next) }
            }
        }
        walk(AXUIElementCreateApplication(app.processIdentifier), 0)
        return lines.joined(separator: "\n")
    }

    private func press(_ target: String) throws -> String {
        guard AXIsProcessTrusted() else { throw Failure("Allow Kelp Guest in the machine's System Settings › Privacy & Security › Accessibility.") }
        let e = refs[target] ?? refs.first { (attr($0.value, kAXTitleAttribute) ?? attr($0.value, kAXDescriptionAttribute)) == target }?.value
        guard let e else { throw Failure("No \(target) in the last ui listing: run ui first.") }
        let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
        guard r == .success else { throw Failure("It can't be pressed (\(r.rawValue)); click it instead.") }
        return "pressed"
    }

    private func attr(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    /// " (x,y w×h)" in screen points: where to click it.
    private func frame(_ e: AXUIElement) -> String {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pos = pv, let size = sv, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return "" }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(unsafeDowncast(pos, to: AXValue.self), .cgPoint, &p)   // its type checked above
        AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &s)
        return " (\(Int(p.x)),\(Int(p.y)) \(Int(s.width))×\(Int(s.height)))"
    }
}

/// The socket's address (a path well under sockaddr_un's 104 bytes: the temporary folder's).
func unixAddress(_ path: String) -> sockaddr_un {
    var a = sockaddr_un()
    a.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &a.sun_path) { b in for (i, c) in path.utf8.prefix(b.count - 1).enumerated() { b[i] = c } }
    return a
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

extension Array {
    func chunked(_ n: Int) -> [[Element]] { stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) } }
}
