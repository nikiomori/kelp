import Foundation

/// A motion page's subtitles (OpenMotion's Captions): cues read from an SRT or a WebVTT file and kept in the page as
/// one block, `<div data-id="captions" data-kelp-captions="box bottom 48">`, a `<p data-id="cap-N" data-start
/// data-duration>` each, which the page shows in their time like any part. How they look (a box, plain, an outline, a
/// highlight; at the bottom, the top or the middle; their size) is the block's attribute, written as `<style
/// id="kelp-captions">`; the cues share one place (the page hides those out of their time, which still take room).
/// An export writes them beside the video as SRT.
public enum Captions {
    public struct Cue: Equatable, Sendable {
        public var start: Double, end: Double, text: String
        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public static let looks = ["box", "plain", "outline", "highlight"], places = ["bottom", "top", "middle"]

    /// The cues of an SRT or a WebVTT file, in order; tags and cue settings left out.
    public static func parse(_ text: String) -> [Cue] {
        var out: [Cue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let at = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[at].components(separatedBy: "-->")
            guard times.count == 2, let start = seconds(times[0]),
                let end = seconds(times[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0])
            else { continue }
            let words = lines[(at + 1)...].joined(separator: " ").replacing(/<[^>]*>/, with: "")
                .trimmingCharacters(in: .whitespaces)
            if !words.isEmpty, end > start { out.append(Cue(start: start, end: end, text: words)) }
        }
        return out
    }

    /// `00:01:02,500`, `01:02.500` or `2.5` as seconds.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(
            separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let n = Double(part) else { return nil }
            total = total * 60 + n
        }
        return total
    }

    /// `page` with its subtitles replaced by `cues`, looking as they did (a box at the bottom, 48, at first).
    public static func write(_ page: String, cues: [Cue]) -> String {
        let look = attribute(page) ?? "box bottom 48"
        let lines = cues.enumerated().map { i, cue in
            "<p data-id=\"cap-\(i + 1)\" data-start=\"\(number(cue.start))\" "
                + "data-duration=\"\(number(cue.end - cue.start))\">\(BoardEdit.escape(cue.text))</p>"
        }
        let block =
            "<div data-id=\"captions\" data-kelp-captions=\"\(look)\">\n" + lines.joined(separator: "\n") + "\n</div>"
        var out = page
        if let old = out.firstMatch(of: /<div data-id="captions" data-kelp-captions="[^"]*">[\s\S]*?\n<\/div>/) {
            out.replaceSubrange(old.range, with: block)
        } else {
            out = BoardEdit.appendToBody(out, block)
        }
        return style(out, look: look)
    }

    /// `page` with its subtitles looking as `look` says ("outline top 56").
    public static func setLook(_ page: String, _ look: String) -> String? {
        guard look.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " }),
            let out = BoardEdit.setAttribute(page, id: "captions", name: "data-kelp-captions", value: look)
        else { return nil }
        return style(out, look: look)
    }

    /// The page's subtitles as an SRT file; empty when it has none.
    public static func srt(_ page: String) -> String {
        let cues = page.matches(
            of: /<p data-id="cap-\d+" data-start="([0-9.]+)" data-duration="([0-9.]+)">([^<]*)<\/p>/)
        return cues.enumerated().map { i, m in
            let start = Double(m.output.1) ?? 0, end = start + (Double(m.output.2) ?? 0)
            return "\(i + 1)\n\(clock(start)) --> \(clock(end))\n\(BoardEdit.unescape(String(m.output.3)))\n"
        }.joined(separator: "\n")
    }

    /// What the page's subtitles look like now (`box bottom 48`), when it has them.
    public static func attribute(_ page: String) -> String? {
        page.firstMatch(of: /data-kelp-captions="([^"]*)"/).map { String($0.output.1) }
    }

    /// The page's `<style id="kelp-captions">` for `look`.
    static func style(_ page: String, look: String) -> String {
        let parts = look.split(separator: " ").map(String.init)
        let kind = parts.first ?? "box", place = parts.count > 1 ? parts[1] : "bottom"
        let size = parts.count > 2 ? Int(parts[2]) ?? 48 : 48
        let at = place == "top" ? "top: 6%" : place == "middle" ? "top: 50%; transform: translateY(-50%)" : "bottom: 6%"
        let face: String
        switch kind {
        case "plain": face = "color: #fff; text-shadow: 0 2px 8px rgba(0,0,0,.6)"
        case "outline": face = "color: #fff; -webkit-text-stroke: \(max(2, size / 16))px #000; paint-order: stroke fill"
        case "highlight": face = "color: #111; background: #ffd60a; padding: .1em .4em; border-radius: .2em"
        default: face = "color: #fff; background: rgba(0,0,0,.65); padding: .2em .5em; border-radius: .25em"
        }
        let css = """
            <style id="kelp-captions">
            [data-kelp-captions] { position: absolute; left: 0; right: 0; \(at); display: grid; justify-items: center; \
            text-align: center; z-index: 50; pointer-events: none; }
            [data-kelp-captions] > p { grid-area: 1 / 1; margin: 0; font-size: \(size)px; font-weight: 600; \
            line-height: 1.25; \(face); }
            </style>
            """
        var out = page
        if let old = out.firstMatch(of: /<style id="kelp-captions">[\s\S]*?<\/style>/) {
            out.replaceSubrange(old.range, with: css)
        } else {
            let end = out.range(of: "</head>", options: .caseInsensitive)?.lowerBound ?? out.startIndex
            out.insert(contentsOf: css + "\n", at: end)
        }
        return out
    }

    static func number(_ v: Double) -> String { String(format: "%g", (v * 1000).rounded() / 1000) }

    /// Seconds as an SRT time, `00:00:01,250`.
    static func clock(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
