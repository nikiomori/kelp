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

    public mutating func read(_ data: Data) {
        guard let re = Self.set, let text = String(data: data, encoding: .isoLatin1) else { return }
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let modes = Range(match.range(at: 1), in: text), let hl = Range(match.range(at: 2), in: text) else {
                continue
            }
            for mode in text[modes].split(separator: ";").compactMap({ Int($0) }) where Self.kept.contains(mode) {
                last.removeAll { $0.mode == mode }
                last.append((mode, text[hl] == "h"))
            }
        }
    }

    /// What puts a new terminal in these modes, sent ahead of the history.
    public var restore: Data { Data(last.map { "\u{1B}[?\($0.mode)\($0.on ? "h" : "l")" }.joined().utf8) }
}
