import Foundation

/// Where a design's controls go (Google Stitch's prototypes): a link to another board is `href="#board:<name>"` on an
/// `<a>`, or `data-link="<name>"` on anything else, where a board's name is its file's without the folder or
/// `.html` (`boards/choose.html` is `choose`). A control that goes nowhere (a button, an `<a>` without an address or
/// with "#") is a dead end: the flow stops there. Read without drawing, for `kelp artifact links` and the tab.
public enum BoardLinks {
    public struct Link: Equatable, Sendable {
        /// The board's file, the control's data-id ("" without one), its words, and the board it goes to (nil: none).
        public var board: String, id: String, words: String, to: String?
    }

    /// A board's name in links: its file's, without the folder or the extension.
    public static func name(_ file: String) -> String {
        ((file as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The board file a link's name points at, among `boards`; nil when none has it.
    public static func file(_ name: String, in boards: [String]) -> String? {
        boards.first { Self.name($0) == name }
    }

    /// The controls of `html` (one board) and where each goes: links to boards, and dead ends. An `<a>` to an address
    /// outside the design, and a field, are neither.
    public static func controls(_ html: String, board: String) -> [Link] {
        html.matches(of: /<(a|button)\b([^>]*)>([\s\S]*?)<\/\1>/.ignoresCase()).compactMap { match in
            let tag = String(match.output.2), words = text(String(match.output.3))
            let id = attribute(tag, "data-id") ?? ""
            if let to = attribute(tag, "data-link") { return Link(board: board, id: id, words: words, to: to) }
            let href = attribute(tag, "href")
            if let href, href.hasPrefix("#board:") {
                return Link(board: board, id: id, words: words, to: String(href.dropFirst("#board:".count)))
            }
            let isLink = match.output.1.lowercased() == "a"
            if isLink, let href, !href.isEmpty, href != "#" { return nil }   // goes somewhere outside the design
            if attribute(tag, "type").map({ ["submit", "reset"].contains($0) }) == true, !isLink { return nil }
            return Link(board: board, id: id, words: words, to: nil)
        }
    }

    /// Every board's controls in `canvas` order, each board read by `read` (its text, nil when it can't be read).
    public static func all(_ canvas: ArtifactCanvas, read: (String) -> String?) -> [Link] {
        canvas.boards.flatMap { b in read(b.file).map { controls($0, board: b.file) } ?? [] }
    }

    /// The lines `kelp artifact links` prints: "welcome:start → choose", a dead end "→ (nothing)", and a link to a
    /// board that isn't there "→ nope (no such board)".
    public static func lines(_ links: [Link], boards: [String]) -> [String] {
        links.map { link in
            let from = name(link.board) + ":" + (link.id.isEmpty ? "«\(link.words)»" : link.id)
            guard let to = link.to else { return from + " → (nothing)" }
            return from + " → " + to + (file(to, in: boards) == nil ? " (no such board)" : "")
        }
    }

    private static func attribute(_ tag: String, _ name: String) -> String? {
        guard let at = tag.range(of: " \(name)=\""), let end = tag[at.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        return BoardEdit.unescape(String(tag[at.upperBound..<end]))
    }

    private static func text(_ html: String) -> String {
        BoardEdit.unescape(html.replacing(/<[^>]*>/, with: "")).split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
