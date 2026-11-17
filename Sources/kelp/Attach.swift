import Core
import Foundation

/// `kelp attach <session>` makes this terminal the session's terminal, like `tmux attach`.
/// The libghostty view runs it, so Ghostty renders the output and the daemon keeps owning the process.
enum Attach {
    /// With `detachKey`, Ctrl+\ ends the attach, for a terminal with no tab to close. The key's second encoding is what
    /// a terminal sends to an agent that asked for the kitty keyboard protocol.
    static func run(_ sessionId: String, detachKey: Bool = false) -> Never {
        let socket = ProcessInfo.processInfo.environment["KELP_SOCKET"] ?? Paths.socket.path
        let fd: Int32
        do { fd = try Unix.connect(socket, patience: 2) } catch {
            fail("kelp attach: daemon not reachable at \(socket): \(error)")
        }
        var ws = winsize()   // A paused agent wakes at this size, so its first screen fits this terminal.
        let hasSize = ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0
        let stream = SessionStream(
            id: sessionId, cols: hasSize ? Int(ws.ws_col) : nil, rows: hasSize ? Int(ws.ws_row) : nil)
        let req: Data
        do {
            req = try Wire.line(RPCRequest(id: nil, method: SessionStream.name, params: stream.params()))
        } catch { fail("kelp attach: \(error)") }
        Unix.writeAll(fd, req)

        // Raw mode sends every key to the agent as typed, and the agent's terminal handles echo and line editing.
        var saved = termios()
        let isTTY = isatty(0) == 1
        if isTTY {
            tcgetattr(0, &saved)
            var raw = saved
            cfmakeraw(&raw)
            tcsetattr(0, TCSANOW, &raw)
        }
        func restore() {
            if isTTY {
                var attributes = saved
                tcsetattr(0, TCSANOW, &attributes)
            }
        }

        // Size changes go over a separate control connection.
        let control = try? RPCClient(socket: socket, patience: 2)
        control?.notify(ClientEvents(events: false))   // It only sends sizes, so it reads no events.
        func sendSize() {
            var ws = winsize()
            guard ioctl(1, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return }
            // Sizes arrive in order, because a notification is written at once and the daemon applies them as they
            // come.
            control?.notify(SessionResize(id: sessionId, cols: Int(ws.ws_col), rows: Int(ws.ws_row)))
        }
        // Clear whatever the login shell printed ("Last login…"). The session's own screen follows.
        _ = "\u{1B}[H\u{1B}[2J\u{1B}[3J".withCString { Darwin.write(1, $0, strlen($0)) }
        sendSize()
        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        // A panel sliding in or a window being dragged resizes the terminal on every frame, and an agent redraws its
        // whole screen for each size, so sizes go at most ten a second. Signals that arrive while this is suspended run
        // it once more, so the last size gets through.
        winch.setEventHandler {
            sendSize()
            winch.suspend()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { winch.resume() }
        }
        winch.resume()

        let original = saved
        Thread.detachNewThread {   // Keyboard → session.
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let bytesRead = read(0, &buf, buf.count)
                if bytesRead <= 0 { break }
                let keys = Data(buf[0..<bytesRead])
                if detachKey, keys.contains(0x1C) || keys.range(of: Data("\u{1B}[92;5".utf8)) != nil {
                    var attributes = original
                    if isTTY { tcsetattr(0, TCSANOW, &attributes) }
                    exit(0)
                }
                if !Unix.writeAll(fd, keys) { break }
            }
        }
        var buf = [UInt8](repeating: 0, count: 65536)   // Session → screen.
        var sized = false
        while true {
            let bytesRead = read(fd, &buf, buf.count)
            if bytesRead <= 0 { break }
            _ = buf.withUnsafeBytes { p in p.baseAddress.map { Darwin.write(1, $0, bytesRead) } }
            // The first bytes come once the session runs. A size sent while a paused session was still waking went
            // nowhere (a size never wakes a session), and the session woke at the size read above, before this
            // terminal was laid out. So the size is sent again now.
            if !sized {
                sized = true
                sendSize()
            }
        }
        winch.cancel()
        restore()
        exit(0)
    }
}
