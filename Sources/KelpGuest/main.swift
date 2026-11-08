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
        if let index = args.firstIndex(of: "--session"), index + 1 < args.count {
            session = args[index + 1]
            args.removeSubrange(index...index + 1)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = unixAddress(socketPath)
        let ok = withUnsafePointer(to: &address) {
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
            let count = read(fd, &buf, buf.count)
            if count <= 0 { break }
            reply.append(contentsOf: buf[0..<count])
        }
        close(fd)
        guard let answer = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return 1 }
        if let error = answer["error"] as? String {
            FileHandle.standardError.write(Data((error + "\n").utf8))
            return 1
        }
        if let text = answer["text"] as? String { print(text) }
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
        var address = unixAddress(socketPath)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        chmod(socketPath, 0o600)
        listen(fd, 16)
        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        listener.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            MainActor.assumeIsolated { self?.serve(client) }   // a read source on the main queue
        }
        listener.resume()
        source = listener
    }

    private func serve(_ fd: Int32) {
        var line = Data(), byte: UInt8 = 0
        while line.count < 1 << 20, read(fd, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
        let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let args = req?["args"] as? [String] ?? []
        Task {
            var reply: [String: Any]
            do { reply = try handle(args) } catch { reply = ["error": "\(error)"] }
            let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var off = 0
                while off < bytes.count {
                    let written = write(fd, base + off, bytes.count - off)
                    if written <= 0 { break }
                    off += written
                }
            }
            close(fd)
        }
    }

    private func handle(_ args: [String]) throws -> [String: Any] {
        switch args.first ?? "" {
        case "status": return ["text": "accessibility: \(AXIsProcessTrusted() ? "on" : "off")"]
        case "ui":
            return [
                "text": try ui(app: args.firstIndex(of: "--app").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil })
            ]
        case "press": return ["text": try press(args.dropFirst().joined(separator: " "))]
        default:
            throw Failure(
                "unknown: \(args.first ?? ""). ui, press, status (the screen is kelp vm screenshot, click, type, key)")
        }
    }

    /// Asks for Accessibility (its dialog on the machine's screen, the first time) unless it has it.
    private func trusted() throws {
        guard !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else { return }
        throw Failure(
            "Kelp Guest needs Accessibility in the machine to read controls: its dialog is on the machine's screen. "
                + "Open System Settings from it and turn Kelp Guest on; for the password it asks, the user presses "
                + "Type Password at the top of this machine's window (kelp vm show <name>). "
                + "Or work from screenshots and clicks, which need nothing.")
    }

    // MARK: Accessibility

    /// The front app's window controls, a line each, indented by depth, with a ref to press: "- button "Save" [ref=e12]".
    private func ui(app name: String?) throws -> String {
        try trusted()
        let running =
            name.flatMap { wanted in
                NSWorkspace.shared.runningApplications.first {
                    $0.localizedName?.caseInsensitiveCompare(wanted) == .orderedSame
                }
            }
            ?? NSWorkspace.shared.frontmostApplication
        guard let app = running else { throw Failure("No app \(name ?? "in front").") }
        refs = [:]
        var lines = ["\(app.localizedName ?? "?") (pid \(app.processIdentifier))"], count = 0
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 14, count < 400 else { return }
            let role = attr(element, kAXRoleAttribute) ?? ""
            let title =
                attr(element, kAXTitleAttribute) ?? attr(element, kAXDescriptionAttribute) ?? attr(
                    element, kAXValueAttribute
                ).map {
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
                refs[ref] = element
                lines.append(
                    String(repeating: "  ", count: depth)
                        + "- \(role.dropFirst(2).lowercased()) \"\(title)\" [ref=\(ref)]" + frame(element))
                next = depth + 1
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                let list = children as? [AXUIElement]
            {
                for child in list { walk(child, next) }
            }
        }
        walk(AXUIElementCreateApplication(app.processIdentifier), 0)
        return lines.joined(separator: "\n")
    }

    private func press(_ target: String) throws -> String {
        try trusted()
        let element =
            refs[target]
            ?? refs.first { (attr($0.value, kAXTitleAttribute) ?? attr($0.value, kAXDescriptionAttribute)) == target }?
            .value
        guard let element else { throw Failure("No \(target) in the last ui listing: run ui first.") }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw Failure("It can't be pressed (\(result.rawValue)); click it instead.") }
        return "pressed"
    }

    private func attr(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let text = value as? String,
            !text.isEmpty
        else { return nil }
        return text
    }

    /// " (x,y w×h)" in screen points: where to click it.
    private func frame(_ element: AXUIElement) -> String {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pv) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sv) == .success,
            let pos = pv, let size = sv, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return "" }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(unsafeDowncast(pos, to: AXValue.self), .cgPoint, &origin)   // its type checked above
        AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
        return " (\(Int(origin.x)),\(Int(origin.y)) \(Int(extent.width))×\(Int(extent.height)))"
    }
}

/// The socket's address (a path well under sockaddr_un's 104 bytes: the temporary folder's).
func unixAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        for (index, byte) in path.utf8.prefix(bytes.count - 1).enumerated() { bytes[index] = byte }
    }
    return address
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
