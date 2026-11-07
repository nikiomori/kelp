import Foundation

/// The terminal modes a program switched on or off (alternate screen, mouse reporting, bracketed paste, cursor keys),
/// read from its output so a terminal that's shown only the tail of it starts in them. Codex sets them once, at start:
/// a terminal attached after its first megabyte scrolled its own scrollback instead of sending the wheel to Codex.
public struct TerminalModes: Sendable {
    /// Each mode's last setting, oldest first: the mouse modes replace one another, the last one set wins.
    private var last: [(mode: Int, on: Bool)] = []
    // Synchronized output (2026) stays out: restored mid-frame, the screen would freeze until the next frame ends it.
    private static let kept: Set<Int> = [
        1, 9, 25, 47, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 1047, 1049, 2004
    ]
    private static let set = try? NSRegularExpression(pattern: #"\x1B\[\?([0-9;]+)([hl])"#)

    public init() {}

    public mutating func read(_ d: Data) {
        guard let re = Self.set, let s = String(data: d, encoding: .isoLatin1) else { return }
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range(at: 1), in: s), let hl = Range(m.range(at: 2), in: s) else { continue }
            for mode in s[r].split(separator: ";").compactMap({ Int($0) }) where Self.kept.contains(mode) {
                last.removeAll { $0.mode == mode }
                last.append((mode, s[hl] == "h"))
            }
        }
    }

    /// What puts a new terminal in these modes, sent ahead of the history.
    public var restore: Data { Data(last.map { "\u{1B}[?\($0.mode)\($0.on ? "h" : "l")" }.joined().utf8) }
}
