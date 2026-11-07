import Core
import Foundation

/// `kelp agents`: who runs and who waits, for a narrow terminal (a phone over SSH) with Kelp's window closed. Enter runs
/// `kelp attach --detach` and comes back here when that ends: a process of its own, so nothing of attach's is left to undo.
extension Main {
    private enum Key { case up, down, enter, yes, no, quit }
    /// Off: autowrap, so a long line is cut by the terminal and no width has to be worked out here.
    private static let enter = "\u{1B}[?1049h\u{1B}[?7l\u{1B}[?25l\u{1B}[2J",
        leave = "\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l"
    /// What an agent may have left on when it was detached from: mouse reports, bracketed paste, focus events, its keyboard mode.
    private static let reset =
        "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1004l\u{1B}[?2004l\u{1B}[<u\u{1B}[0m"
    private static let keys: [[UInt8]: Key] = [
        [27, 91, 65]: .up, [27, 79, 65]: .up, [107]: .up, [27, 91, 66]: .down, [27, 79, 66]: .down, [106]: .down,
        [13]: .enter, [10]: .enter, [121]: .yes, [89]: .yes, [110]: .no, [78]: .no, [113]: .quit, [3]: .quit,
        [4]: .quit
    ]

    static func agents(_ c: RPCClient) async throws {
        // What ends these agents, said where someone away from the Mac will read it.
        var warning: String?
        do {
            if try await !c.call(DaemonBackgroundAllowed()) {
                warning = "Quitting Kelp ends these: allow it in Login Items"
            }
        } catch {}   // an older kelpd can't say
        guard isatty(0) == 1, isatty(1) == 1 else {
            for r in try await board(c).rows { print("\(r.title)  [\(r.id.prefix(8))]\n  \(r.detail)") }
            if let warning { print(warning) }
            return
        }
        var saved = termios()
        tcgetattr(0, &saved)
        var raw = saved
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
        defer {
            put(leave)
            tcsetattr(0, TCSANOW, &saved)
        }
        put(enter)
        var selected: String?, note: String?, shown = ""
        while true {
            let (rows, paused) = try await board(c)
            let at = rows.firstIndex { $0.id == selected } ?? 0
            selected = rows.isEmpty ? nil : rows[at].id
            let frame = render(rows, at: at, paused: paused, note: note ?? warning)
            if frame != shown {
                put(frame)
                shown = frame
            }
            guard let key = readKey() else { continue }
            note = nil
            switch key {
            case .quit: return
            case .up, .down:
                if !rows.isEmpty { selected = rows[max(0, min(rows.count - 1, at + (key == .up ? -1 : 1)))].id }
            case .enter:
                guard let id = selected else { break }
                put(leave)
                runAttach(id)
                put(reset + enter)
                shown = ""
            case .yes, .no:
                guard let id = selected, rows[at].status == .waiting else { break }
                if try await !c.call(SessionChoose(id: id, answer: key == .yes ? "allow" : "deny")) {
                    note = "No yes/no on its screen: press Enter to open it"
                }
            }
        }
    }

    private static func board(_ c: RPCClient) async throws -> (rows: [AgentBoard.Row], paused: Int) {
        let all = try await c.call(SessionList())
        return (
            AgentBoard.rows(all, worktrees: try await c.call(WorktreeList()), repos: try await c.call(RepoList())),
            AgentBoard.paused(all)
        )
    }

    private static func render(_ rows: [AgentBoard.Row], at: Int, paused: Int, note: String?) -> String {
        var ws = winsize()
        let height = ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0 ? Int(ws.ws_row) : 24
        let fits = max(1, (height - 2 - (note == nil ? 0 : 1)) / 2), top = max(0, at - fits + 1)   // two lines each
        let asking = rows.filter { $0.status == .waiting }.count
        var lines = [
            "\u{1B}[1mAgents\u{1B}[0m \(rows.count)" + (asking > 0 ? " · \(asking) need you" : "")
                + (paused > 0 ? " · \(paused) paused" : "")
        ]
        if rows.isEmpty { lines.append("No agents running") }
        for (i, r) in rows.enumerated().dropFirst(top).prefix(fits) {
            let title = "\(mark(r.status)) \(r.title)"
            lines.append(i == at ? "\u{1B}[7m\(title)\u{1B}[0m" : title)
            lines.append("  \u{1B}[2m\(r.detail)\u{1B}[0m")
        }
        if let note { lines.append(note) }
        lines.append(
            (rows.indices.contains(at) && rows[at].status == .waiting ? "y/n answer · " : "")
                + "⏎ open, Ctrl+\\ back · q quit")
        return "\u{1B}[H" + lines.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n") + "\u{1B}[J"
    }

    private static func mark(_ s: AgentStatus) -> String {
        switch s {
        case .waiting: "\u{1B}[33m?\u{1B}[39m"
        case .error: "\u{1B}[31m!\u{1B}[39m"
        case .working: "\u{1B}[36m●\u{1B}[39m"
        case .done: "\u{1B}[32m✓\u{1B}[39m"
        default: "·"
        }
    }

    /// Waits a second for a key, so the list keeps up meanwhile. A terminal that's gone reads as quit.
    private static func readKey() -> Key? {
        var pollFD = pollfd(fd: 0, events: Int16(POLLIN), revents: 0), buf = [UInt8](repeating: 0, count: 16)
        guard poll(&pollFD, 1, 1000) > 0 else { return nil }
        let bytesRead = read(0, &buf, buf.count)
        return bytesRead <= 0 ? .quit : keys[Array(buf[0..<bytesRead])]
    }

    private static func runAttach(_ id: String) {
        let me = CommandLine.arguments[0], words = [me, "attach", id, "--detach"]
        let argv = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0, status: Int32 = 0
        // Not `Process`: it starts a process group of its own, and that can't read this terminal.
        if posix_spawnp(&pid, me, nil, nil, argv, environ) == 0 { waitpid(pid, &status, 0) }
    }

    private static func put(_ s: String) { _ = s.withCString { Darwin.write(1, $0, strlen($0)) } }
}
