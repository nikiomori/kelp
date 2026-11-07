import AppKit
import ApplicationServices

// Kelp Guest: inside a Kelp macOS machine, its apps' controls by name. The screen itself (screenshots, clicks, keys) is
// read and driven from the Mac's side by kelp-vm and needs nothing in here; this needs Accessibility, asked for the
// first time `ui` runs. Started at login (a LaunchAgent); run over SSH with arguments, the same program asks it:
//   KelpGuest ui [--app NAME]             the front app's controls, a line each, with refs: "- button "Save" [ref=e12]"
//   KelpGuest press REF|TITLE             presses a control through Accessibility: no pointer
//   KelpGuest status                      whether it has Accessibility

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
        if let i = args.firstIndex(of: "--session"), i + 1 < args.count {
            session = args[i + 1]
            args.removeSubrange(i...i + 1)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = unixAddress(socketPath)
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            FileHandle.standardError.write(
                Data("Kelp Guest isn't running: open the machine's window and sign in.\n".utf8))
            return 3
        }
        let request = (try? JSONSerialization.data(withJSONObject: ["args": args, "session": session])) ?? Data()
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        _ = write(fd, "\n", 1)
        var reply = Data(), buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
        }
        close(fd)
        guard let r = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return 1 }
        if let e = r["error"] as? String {
            FileHandle.standardError.write(Data((e + "\n").utf8))
            return 1
        }
        if let text = r["text"] as? String { print(text) }
        return 0
    }
}

/// The app side: answers on a Unix socket, one request per connection, on the main thread.
@MainActor
final class Server {
    private var source: DispatchSourceRead?
    private var refs: [String: AXUIElement] = [:]

    func start() {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = unixAddress(socketPath)
        _ = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
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
    }

    private func serve(_ fd: Int32) {
        var line = Data(), byte: UInt8 = 0
        while line.count < 1 << 20, read(fd, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
        let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let args = req?["args"] as? [String] ?? []
        Task {
            var reply: [String: Any]
            do { reply = try handle(args) } catch { reply = ["error": "\(error)"] }
            let d = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
            d.withUnsafeBytes { p in
                guard let base = p.baseAddress else { return }
                var off = 0
                while off < p.count {
                    let n = write(fd, base + off, p.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(fd)
        }
    }

    private func handle(_ a: [String]) throws -> [String: Any] {
        switch a.first ?? "" {
        case "status": return ["text": "accessibility: \(AXIsProcessTrusted() ? "on" : "off")"]
        case "ui":
            return ["text": try ui(app: a.firstIndex(of: "--app").flatMap { a.count > $0 + 1 ? a[$0 + 1] : nil })]
        case "press": return ["text": try press(a.dropFirst().joined(separator: " "))]
        default:
            throw Failure(
                "unknown: \(a.first ?? ""). ui, press, status (the screen is kelp vm screenshot, click, type, key)")
        }
    }

    /// Asks for Accessibility (its dialog on the machine's screen, the first time) unless it has it.
    private func trusted() throws {
        guard !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else { return }
        throw Failure(
            "Kelp Guest needs Accessibility in the machine to read controls: its dialog is on the machine's screen. "
                + "Open System Settings from it, turn Kelp Guest on, and `kelp vm password <name>` types the password it asks. "
                + "Or work from screenshots and clicks, which need nothing.")
    }

    // MARK: Accessibility

    /// The front app's window controls, a line each, indented by depth, with a ref to press: "- button "Save" [ref=e12]".
    private func ui(app name: String?) throws -> String {
        try trusted()
        let running =
            name.flatMap { n in
                NSWorkspace.shared.runningApplications.first {
                    $0.localizedName?.caseInsensitiveCompare(n) == .orderedSame
                }
            }
            ?? NSWorkspace.shared.frontmostApplication
        guard let app = running else { throw Failure("No app \(name ?? "in front").") }
        refs = [:]
        var lines = ["\(app.localizedName ?? "?") (pid \(app.processIdentifier))"], count = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 14, count < 400 else { return }
            let role = attr(e, kAXRoleAttribute) ?? ""
            let title =
                attr(e, kAXTitleAttribute) ?? attr(e, kAXDescriptionAttribute) ?? attr(e, kAXValueAttribute).map {
                    String($0.prefix(60))
                } ?? ""
            let interesting =
                !title.isEmpty
                || ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXPopUpButton", "AXMenuItem", "AXLink"]
                    .contains(role)
            var next = depth
            if interesting, role != "AXApplication" {
                count += 1
                let ref = "e\(count)"
                refs[ref] = e
                lines.append(
                    String(repeating: "  ", count: depth)
                        + "- \(role.dropFirst(2).lowercased()) \"\(title)\" [ref=\(ref)]" + frame(e))
                next = depth + 1
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
                let list = children as? [AXUIElement]
            {
                for c in list { walk(c, next) }
            }
        }
        walk(AXUIElementCreateApplication(app.processIdentifier), 0)
        return lines.joined(separator: "\n")
    }

    private func press(_ target: String) throws -> String {
        try trusted()
        let e =
            refs[target]
            ?? refs.first { (attr($0.value, kAXTitleAttribute) ?? attr($0.value, kAXDescriptionAttribute)) == target }?
            .value
        guard let e else { throw Failure("No \(target) in the last ui listing: run ui first.") }
        let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
        guard r == .success else { throw Failure("It can't be pressed (\(r.rawValue)); click it instead.") }
        return "pressed"
    }

    private func attr(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let s = v as? String, !s.isEmpty
        else { return nil }
        return s
    }

    /// " (x,y w×h)" in screen points: where to click it.
    private func frame(_ e: AXUIElement) -> String {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
            AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
            let pos = pv, let size = sv, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return "" }
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
    withUnsafeMutableBytes(of: &a.sun_path) { b in for (i, c) in path.utf8.prefix(b.count - 1).enumerated() { b[i] = c }
    }
    return a
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
