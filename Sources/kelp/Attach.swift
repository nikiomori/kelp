import Foundation
import Core

/// `kelp attach <session>`: this terminal becomes the session's terminal (like `tmux attach`).
/// The libghostty view runs it, so Ghostty renders and the daemon keeps owning the process.
enum Attach {
    static func run(_ sessionId: String) -> Never {
        let socket = ProcessInfo.processInfo.environment["KELP_SOCKET"] ?? Paths.socket.path
        guard let fd = try? Unix.connect(socket, patience: 2) else { fail("kelp attach: daemon not reachable at \(socket)") }
        var ws = winsize()   // a paused agent wakes at this size, so its first screen isn't drawn for another width
        let size: [String: JSONValue] = ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 ? ["cols": .int(Int(ws.ws_col)), "rows": .int(Int(ws.ws_row))] : [:]
        guard let req = try? Wire.line(RPCRequest(id: nil, method: "session.stream",
                                                  params: .object(["id": .string(sessionId)].merging(size) { a, _ in a })))
        else { exit(1) }
        Unix.writeAll(fd, req)

        // Raw mode: every key goes to the agent as typed; the agent's terminal handles echo and line editing.
        var saved = termios()
        let isTTY = isatty(0) == 1
        if isTTY { tcgetattr(0, &saved); var raw = saved; cfmakeraw(&raw); tcsetattr(0, TCSANOW, &raw) }
        func restore() { if isTTY { var s = saved; tcsetattr(0, TCSANOW, &s) } }

        // Size changes go over a separate control connection.
        let control = try? RPCClient(socket: socket, patience: 2)
        control?.notify(ClientEvents(events: false))   // it only sends sizes: no events to read
        func sendSize() {
            var ws = winsize()
            guard ioctl(1, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return }
            // In order: a notification is written now, and the daemon applies them as they come.
            control?.notify(SessionResize(id: sessionId, cols: Int(ws.ws_col), rows: Int(ws.ws_row)))
        }
        // Clear whatever the login shell printed ("Last login…"); the session's own screen follows.
        _ = "\u{1B}[H\u{1B}[2J\u{1B}[3J".withCString { Darwin.write(1, $0, strlen($0)) }
        sendSize()
        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        // A panel sliding in or a window being dragged resizes the terminal on every frame, and an agent redraws its whole
        // screen for each size: ten a second at most. Signals while suspended run this once more, so the last size gets there.
        winch.setEventHandler {
            sendSize()
            winch.suspend()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { winch.resume() }
        }
        winch.resume()

        Thread.detachNewThread {   // keyboard → session
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(0, &buf, buf.count)
                if n <= 0 { break }
                if !Unix.writeAll(fd, Data(buf[0..<n])) { break }
            }
        }
        var buf = [UInt8](repeating: 0, count: 65536)   // session → screen
        var sized = false
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            _ = buf.withUnsafeBytes { p in p.baseAddress.map { Darwin.write(1, $0, n) } }
            // The first bytes come once the session runs. A size sent while a paused one was still waking went nowhere
            // (a size never wakes one), and it woke at the size read above, before this terminal was laid out.
            if !sized { sized = true; sendSize() }
        }
        winch.cancel()
        restore()
        exit(0)
    }
}
