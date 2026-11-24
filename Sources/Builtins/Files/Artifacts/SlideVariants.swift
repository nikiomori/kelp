import Foundation

/// Other layouts of a slide (Gamma): the agent writes them as slides right after it, each starting with a
/// `<!-- variant -->` line. A slide and the variants after it are a group; keeping one puts its text in the group's
/// place, without the marker.
enum SlideVariants {
    struct Slide { var lines: Range<Int>, first: Int, variant: Bool }

    /// The slides of `source` (cut at a rule after a blank line), each with its first written line (from 1).
    static func slides(_ source: String) -> [Slide] {
        let lines = source.components(separatedBy: "\n")
        let blank = { (i: Int) in i < 0 || lines[i].trimmingCharacters(in: .whitespaces).isEmpty }
        let rule = { (i: Int) in
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            return t.count >= 3 && Set(t).count == 1 && "-*_".contains(t.first ?? " ") && blank(i - 1)
        }
        var out: [Slide] = [], start = 0
        for i in 0...lines.count where i == lines.count || rule(i) {
            let body = start..<i
            let written = body.filter { !blank($0) }
            let variant =
                written.first.map { lines[$0].trimmingCharacters(in: .whitespaces) == "<!-- variant -->" } ?? false
            let first = written.first {
                !variant || lines[$0].trimmingCharacters(in: .whitespaces) != "<!-- variant -->"
            }
            if let first { out.append(Slide(lines: body, first: first + 1, variant: variant)) }
            start = i + 1
        }
        return out
    }

    /// Each slide that has variants after it, with them: their first written lines.
    static func groups(_ source: String) -> [[Int]] {
        var out: [[Int]] = []
        for slide in slides(source) {
            if slide.variant, !out.isEmpty { out[out.count - 1].append(slide.first) } else { out.append([slide.first]) }
        }
        return out.filter { $0.count > 1 }
    }

    /// `source` with the group of the slide whose first written line is `line` replaced by that slide alone.
    static func keep(_ source: String, line: Int) -> String? {
        let all = slides(source)
        guard let at = all.firstIndex(where: { $0.first == line }) else { return nil }
        var start = at
        while start > 0, all[start].variant { start -= 1 }
        var end = start
        while end + 1 < all.count, all[end + 1].variant { end += 1 }
        guard end > start else { return nil }
        var lines = source.components(separatedBy: "\n")
        let kept = lines[all[at].lines].filter { $0.trimmingCharacters(in: .whitespaces) != "<!-- variant -->" }
        // From the group's first line to the end of its last slide (the rules between them go too).
        lines.replaceSubrange(all[start].lines.lowerBound..<all[end].lines.upperBound, with: kept)
        return lines.joined(separator: "\n")
    }
}
