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

    public static let looks = ["box", "plain", "outline", "highlight", "bold", "pill", "serif", "quiet"],
        places = ["bottom", "top", "middle"]

    /// The cues of an SRT or a WebVTT file, in order; their tags and cue settings left out.
    public static func parse(_ text: String) -> [Cue] {
        var out: [Cue] = []
        // A line of only spaces between cues still parts them.
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: /\n[ \t]*\n/)
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let at = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[at].components(separatedBy: "-->")
            guard times.count == 2, let start = seconds(times[0]),
                let end = seconds(times[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0])
            else { continue }
            // The formats' own tags only (WebVTT's c i b u ruby rt v lang and times, SRT's font): a "<" in the words
            // stays; an entity is read as its character.
            let tags = /<\/?(?:c|i|b|u|ruby|rt|v|lang|font)(?:[.\s][^<>]*)?>|<(?:\d{2,}:)?\d{2}:\d{2}\.\d{3}>/
            let words = BoardEdit.unescape(lines[(at + 1)...].joined(separator: " ").replacing(tags, with: ""))
                .replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
            if !words.isEmpty, end > start { out.append(Cue(start: start, end: end, text: words)) }
        }
        return out
    }

    /// Cues from typed `text`, a line each (empty lines left out), shared out over `span` by how long each line is,
    /// so a longer line stays on longer (OpenMotion's manual captions). A cue's edge within a quarter of a second of
    /// one of `beats` moves onto it.
    public static func timed(_ text: String, over span: ClosedRange<Double>, beats: [Double] = []) -> [Cue] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let weights = lines.map { Double(max($0.count, 8)) }, total = weights.reduce(0, +)
        guard total > 0, span.upperBound > span.lowerBound else { return [] }
        let snap = { (t: Double) in
            beats.min(by: { abs($0 - t) < abs($1 - t) }).flatMap { abs($0 - t) <= 0.25 ? $0 : nil } ?? t
        }
        var at = span.lowerBound, out: [Cue] = []
        for (line, weight) in zip(lines, weights) {
            let end = at + (span.upperBound - span.lowerBound) * weight / total
            let start = out.isEmpty ? snap(at) : out[out.count - 1].end
            out.append(Cue(start: start, end: max(start + 0.2, snap(end)), text: line))
            at = end
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
            "<p data-id=\"cap-\(i + 1)\" data-start=\"\(MotionPresets.number(cue.start))\" "
                + "data-duration=\"\(MotionPresets.number(cue.end - cue.start))\">\(BoardEdit.escape(cue.text))</p>"
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

    /// The page's subtitles as an SRT file, timed from the start of `span` and only those within it (a video of the
    /// work area); empty when it has none. A cue styled by hand keeps its words (a `<br>` as a new line).
    public static func srt(_ page: String, over span: ClosedRange<Double>? = nil) -> String {
        let cues = page.matches(
            of: /<p data-id="cap-\d+" data-start="([0-9.]+)" data-duration="([0-9.]+)">(.*?)<\/p>/.dotMatchesNewlines())
        let (from, to) = (span?.lowerBound ?? 0, span?.upperBound ?? .infinity)
        let kept = cues.compactMap { m -> (start: Double, end: Double, text: String)? in
            let start = Double(m.output.1) ?? 0, end = start + (Double(m.output.2) ?? 0)
            guard end > from, start < to else { return nil }
            let words = String(m.output.3).replacing(/<br\s*\/?>/, with: "\n").replacing(/<[^>]*>/, with: "")
            return (max(start, from) - from, min(end, to) - from, BoardEdit.unescape(words))
        }
        return kept.enumerated().map { i, c in "\(i + 1)\n\(clock(c.start)) --> \(clock(c.end))\n\(c.text)\n" }
            .joined(separator: "\n")
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
        case "bold":
            face =
                "color: #ffd60a; text-transform: uppercase; font-weight: 900; letter-spacing: .02em; "
                + "-webkit-text-stroke: \(max(2, size / 12))px #000; paint-order: stroke fill"
        case "pill": face = "color: #111; background: #fff; padding: .2em .8em; border-radius: 999px"
        case "serif":
            face = "color: #fff; font-family: Georgia, serif; font-style: italic; text-shadow: 0 2px 10px #000"
        case "quiet":
            face = "color: rgba(255,255,255,.9); background: rgba(0,0,0,.4); padding: .15em .45em; font-weight: 500"
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

    /// Seconds as an SRT time, `00:00:01,250`.
    static func clock(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
