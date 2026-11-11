import Foundation

/// A design on this Mac: `canvas.json` names its boards (one screen each, a fragment of HTML in `boards/`), and Kelp
/// draws the rest: the frames, the rows of variants, each board in light and dark, the page around it from the
/// project's design system (`.kelp/design/`). The agent writes only what differs from screen to screen.
public struct ArtifactCanvas: Codable, Equatable, Sendable {
    public var boards: [Board]

    public struct Board: Codable, Equatable, Sendable {
        /// Its file, under the artifact's folder (`boards/A-welcome.html`).
        public var file: String
        /// The row it sits in ("A. Steps one at a time"): rows show in the order of their first board.
        public var row: String?
        public var title: String?
        /// Its width in CSS pixels; `h` only for a fixed frame (a phone, a poster), else it's as tall as what it holds.
        public var w: Int?, h: Int?
        public init(file: String, row: String? = nil, title: String? = nil, w: Int? = nil, h: Int? = nil) {
            self.file = file
            self.row = row
            self.title = title
            self.w = w
            self.h = h
        }
    }

    public init(boards: [Board]) { self.boards = boards }

    /// The boards by row, in order: a board without a row is a row of its own.
    public var rows: [(title: String?, boards: [Board])] {
        var rows: [(title: String?, boards: [Board])] = []
        for board in boards {
            if let row = board.row, let i = rows.firstIndex(where: { $0.title == row }) {
                rows[i].boards.append(board)
            } else {
                rows.append((board.row, [board]))
            }
        }
        return rows
    }

    /// The canvas in `json`; nil for one that isn't (half-written, or not a canvas).
    public static func read(_ json: String) -> ArtifactCanvas? {
        let canvas: ArtifactCanvas
        do { canvas = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) } catch { return nil }
        // A board is a file in the artifact's own folder: a path out of it is no board.
        return ArtifactCanvas(boards: canvas.boards.filter { !$0.file.hasPrefix("/") && !$0.file.contains("..") })
    }

    /// What `kelp artifact new design` writes: no boards yet.
    public static let empty = "{\n  \"boards\": []\n}\n"
}

/// A canvas with the text of each of its boards: what the tab draws (from the files as they are, or from a kept
/// version), and what a version of a design keeps (`versions/<n>.json`), so an older one shows with the boards it had.
public struct CanvasSnapshot: Codable, Equatable, Sendable {
    public var canvas: String
    /// Each board's text by its file; a board without one is missing.
    public var boards: [String: String]

    public init(canvas: String, boards: [String: String]) {
        self.canvas = canvas
        self.boards = boards
    }

    /// The canvas `json` with its boards as they are in `folder` now.
    public static func live(json: String, folder: URL) -> CanvasSnapshot {
        var boards: [String: String] = [:]
        for board in ArtifactCanvas.read(json)?.boards ?? [] {
            boards[board.file] = Artifacts.small(folder.appendingPathComponent(board.file).path, limit: 4 << 20)
                .map { String(decoding: $0, as: UTF8.self) }
        }
        return CanvasSnapshot(canvas: json, boards: boards)
    }

    /// A kept version's text; nil for one that isn't a snapshot.
    public static func read(_ text: String) -> CanvasSnapshot? {
        do { return try JSONDecoder().decode(Self.self, from: Data(text.utf8)) } catch { return nil }
    }

    /// As a version keeps it: keys sorted, so the same canvas is the same bytes and makes no new version.
    public var data: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        do { return try encoder.encode(self) } catch { return nil }
    }
}

/// The project's design system, which every design on this Mac is drawn with: `tokens.json` (colours per theme, fonts,
/// sizes, spacing, radii), `kit.css` (its components as classes) and `DESIGN.md` (how to use them, in words).
public enum DesignSystem {
    public static let folder = ".kelp/design"
    public static let files = ["DESIGN.md", "tokens.json", "kit.css"]

    public static func dir(root: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(folder) }

    /// `tokens.json` as CSS custom properties for each theme. A group of colours (`color`) gives `--<name>`, any other
    /// group `--<group>-<name>`; a value is one string for both themes or `{"light": …, "dark": …}`. Nothing that could
    /// end the declaration (`;`, `{`, `}`, `<`) passes: the values land in a page's `<style>`.
    public static func css(tokens json: String) -> (light: String, dark: String) {
        let object: JSONValue
        do { object = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) } catch { return ("", "") }
        guard case .object(let groups) = object else { return ("", "") }
        var light: [String] = [], dark: [String] = []
        for (group, value) in groups.sorted(by: { $0.key < $1.key }) {
            guard case .object(let tokens) = value, isName(group) else { continue }
            for (name, token) in tokens.sorted(by: { $0.key < $1.key }) where isName(name) {
                let property = group == "color" ? "--\(name)" : "--\(group)-\(name)"
                let values = token.string.map { ($0, $0) } ?? (token["light"]?.string, token["dark"]?.string)
                if let value = values.0, isValue(value) { light.append("\(property): \(value);") }
                if let value = values.1 ?? values.0, isValue(value) { dark.append("\(property): \(value);") }
            }
        }
        return (light.joined(separator: " "), dark.joined(separator: " "))
    }

    static func isName(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    private static func isValue(_ s: String) -> Bool { !s.contains(where: { ";{}<\n".contains($0) }) }
}

/// A board's levers, moved in Kelp without its agent: a line at its top, `<!-- tweak --highlight: #1f7a5a -->`
/// (a colour) or `<!-- tweak --gap: 12px (8px, 12px, 16px) -->` (one of those). The board uses `var(--highlight)`.
public struct Tweak: Equatable, Sendable, Encodable {
    public var name: String, value: String
    /// Its choices; empty for a colour.
    public var options: [String]

    public var isColor: Bool { options.isEmpty && value.hasPrefix("#") }

    private static var line: Regex<(Substring, Substring, Substring, Substring?)> {
        /<!--\s*tweak\s+(--[A-Za-z0-9_-]+)\s*:\s*([^<>;()]+?)\s*(?:\(([^<>;()]*)\))?\s*-->/
    }

    /// The tweaks in a board, in order; at most 8.
    public static func all(in html: String) -> [Tweak] {
        html.matches(of: line).prefix(8).map { m in
            let options = m.output.3.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            return Tweak(name: String(m.output.1), value: String(m.output.2), options: options ?? [])
        }
    }

    /// The board with tweak `name` set to `value`; nil when it has no such tweak or the value could end the comment.
    public static func set(_ name: String, to value: String, in html: String) -> String? {
        guard !value.contains(where: { "<>;()\n".contains($0) }),
            let m = html.matches(of: line).first(where: { $0.output.1 == name })
        else { return nil }
        var out = html
        out.replaceSubrange(m.output.2.startIndex..<m.output.2.endIndex, with: value)
        return out
    }

    /// The board's tweaks as CSS declarations, for its page.
    public static func css(_ tweaks: [Tweak]) -> String {
        tweaks.map { "\($0.name): \($0.value);" }.joined(separator: " ")
    }
}
