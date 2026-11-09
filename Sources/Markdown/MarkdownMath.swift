import Foundation

/// TeX math in Markdown, as GitHub reads it: `$…$` inline, `$$…$$` displayed, `` $`…`$ `` and ```` ```math ```` blocks.
/// Taken out before cmark parses (its emphasis and escapes would eat `_`, `*` and `\`), each left as a mark of
/// private-use characters cmark keeps as they are, and put back as `<span class='kelp-math'>` with its TeX as text;
/// `MarkdownHTML.math` draws them in the page with the bundled KaTeX.
/// ponytail: code is skipped when fenced or in backticks, not when indented by four spaces.
struct MarkdownMath {
    private(set) var formulas: [(tex: String, display: Bool)] = []

    /// `md` with each formula a mark; a `$$` block keeps its lines (blank ones after its mark), for `marking`.
    mutating func takeOut(_ md: String) -> String {
        guard md.contains("$") else { return md }
        var out = "", fence: Substring?
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if let marker = ["```", "~~~"].first(where: trimmed.hasPrefix) {
                fence = trimmed.prefix { $0 == marker.first }
            } else if trimmed.hasPrefix("$$"), let end = blockEnd(lines, from: index) {
                let indent = line.prefix { $0 == " " }
                let tex = lines[index...end].joined(separator: "\n").drop { $0 == " " }.dropFirst(2)
                out += indent + mark(String(tex.dropLast(2)), display: true)
                out += String(repeating: "\n", count: end - index + 1)
                index = end + 1
                continue
            } else {
                out += inline(line)
                out += "\n"
                index += 1
                continue
            }
            out += line + "\n"
            index += 1
        }
        return String(out.dropLast())
    }

    /// The line a `$$` block that opens on `start` closes on: one that ends with `$$` (the same line, past the opening,
    /// or one before a blank line). A `$$` mid-line is inline.
    private func blockEnd(_ lines: [Substring], from start: Int) -> Int? {
        let first = lines[start].drop { $0 == " " }.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if first.contains("$$") { return first.count > 2 && first.hasSuffix("$$") ? start : nil }
        for index in lines.indices.dropFirst(start + 1) {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasSuffix("$$") { return index }
        }
        return nil
    }

    /// One line's inline formulas; code spans and `\$` stay as they are.
    private mutating func inline(_ line: Substring) -> String {
        guard line.contains("$") else { return String(line) }
        let chars = Array(line)
        var out = "", i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(contentsOf: [c, chars[i + 1]])
                i += 2
            } else if c == "`" {
                let run = chars[i...].prefix { $0 == "`" }.count
                let close = codeEnd(chars, from: i + run, run: run)
                out += String(chars[i..<(close ?? i + run)])
                i = close ?? i + run
            } else if c == "$", let (tex, display, next) = formula(chars, at: i) {
                out += mark(tex, display: display)
                i = next
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Past the backtick run of `run` that closes a code span opened before `start`.
    private func codeEnd(_ chars: [Character], from start: Int, run: Int) -> Int? {
        var i = start
        while i < chars.count {
            guard chars[i] == "`" else {
                i += 1
                continue
            }
            let length = chars[i...].prefix { $0 == "`" }.count
            if length == run { return i + length }
            i += length
        }
        return nil
    }

    /// A formula opening at `chars[at]` (a `$`): its TeX, whether it's `$$`, and where the text goes on.
    /// `$…$` opens before a non-space and closes after one, not before a digit: "$5 and $6" stays money.
    private func formula(_ chars: [Character], at start: Int) -> (String, Bool, Int)? {
        let text = String(chars[start...])
        if let m = text.prefixMatch(of: /\$`([^`]+)`\$/) { return (String(m.1), false, start + m.0.count) }
        if let m = text.prefixMatch(of: /\$\$(.+?)\$\$/) { return (String(m.1), true, start + m.0.count) }
        guard let m = text.prefixMatch(of: /\$((?:\\.|[^\\$])+?)\$(?!\d)/),
            m.1.first?.isWhitespace == false, m.1.last?.isWhitespace == false
        else { return nil }
        return (String(m.1), false, start + m.0.count)
    }

    private mutating func mark(_ tex: String, display: Bool) -> String {
        formulas.append((tex, display))
        return "\u{E000}\(formulas.count - 1)\u{E001}"
    }

    /// `html` with each mark its formula, TeX as text. Single quotes: a mark in an attribute (an image's alt) stays
    /// text.
    func putBack(_ html: String) -> String {
        guard !formulas.isEmpty else { return html }
        return html.replacing(/\x{E000}(\d+)\x{E001}/) { match in
            guard let index = Int(match.1), index < formulas.count else { return "" }
            let (tex, display) = formulas[index]
            return Self.span(tex, display: display)
        }
    }

    static func span(_ tex: String, display: Bool) -> String {
        "<span class='kelp-math\(display ? " kelp-math-display" : "")'>\(MarkdownHTML.esc(tex))</span>"
    }
}
