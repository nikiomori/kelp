import Foundation

/// Kelp's runner for iOS machines: a tiny Xcode project (a host app and a UI-testing bundle), its files in Resources/
/// (runner-*.txt: not Kelp's own code), written into the machine's folder and built there with the user's Xcode
/// (`xcodebuild build-for-testing`). Its one test never ends: it answers on the Mac's loopback what agents ask of the
/// simulator's screen (`kelp vm click`, `ui`, `press`…), through XCUITest: no permission on this Mac, no pointer of the user's.
public enum IOSRunner {
    /// Path in the project → contents; nil when this build lacks them.
    public static var files: [String: String]? {
        let names = [
            "KelpRunner.xcodeproj/project.pbxproj": "runner-pbxproj",
            "KelpRunner.xcodeproj/xcshareddata/xcschemes/KelpRunner.xcscheme": "runner-scheme",
            "Host/App.swift": "runner-app", "Runner/Runner.swift": "runner-runner"
        ]
        var files: [String: String] = [:]
        for (path, name) in names {
            guard let text = Paths.resource(name, "txt") else { return nil }
            files[path] = text
        }
        return files
    }
}

/// One request to an iOS machine's runner on the Mac's loopback (no Local Network permission needed there): a JSON line
/// out, the JSON answer back; nil when it doesn't answer.
public enum IOSRunnerClient {
    public static func ask(port: Int, _ request: [String: Any], wait: Int32 = 120_000) -> [String: Any]? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var line: Data
        do { line = try JSONSerialization.data(withJSONObject: request) } catch { return nil }
        guard result == 0 else { return nil }
        line.append(0x0A)
        Unix.noSigPipe(fd)
        guard Unix.writeAll(fd, line) else { return nil }
        var reply = Data(), buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, wait) > 0 else { return nil }
            let count = read(fd, &buf, buf.count)
            if count <= 0 { break }
            reply.append(contentsOf: buf[0..<count])
        }
        do { return try JSONSerialization.jsonObject(with: reply) as? [String: Any] } catch { return nil }
    }
}
