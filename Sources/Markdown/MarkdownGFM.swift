import Foundation
import SwiftMarkdown

/// What GitHub adds to cmark-gfm that READMEs use: alerts (`> [!NOTE]`), footnotes (`[^1]`), bare links and the safe
/// part of HTML (`<details>`, `<kbd>`, `<img width>`, `<picture>`…), tag by tag and attribute by attribute from a list:
/// no script, no style, no event handler, no `javascript:` link.
extension HTMLWriter {
    // MARK: HTML

    private static let tags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "center", "cite", "code", "dd", "del", "details", "div", "dl", "dt", "em",
        "h1", "h2", "h3",
        "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "picture", "pre", "q", "s", "samp",
        "small", "source", "span",
        "strike", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "u", "ul",
        "var"
    ]
    private static let attributes: [String: Set<String>] = [
        "a": ["href", "name"], "img": ["src", "alt", "width", "height"], "source": ["srcset", "media", "type"],
        "details": ["open"],
        "td": ["colspan", "rowspan"], "th": ["colspan", "rowspan"], "ol": ["start", "type"], "li": ["value"]
    ]
    private static let everywhere: Set<String> = ["align", "title", "dir", "lang"]
    private static let urls: Set<String> = ["href", "src", "srcset"]

    /// A whole tag at `c[i]` whose name is on the list, written back with only the attributes on the list.
    func htmlTag(_ c: [Character], _ i: Int) -> (String, Int)? {
        guard let gt = c[i...].prefix(1000).firstIndex(of: ">") else { return nil }
        let raw = String(c[i...gt])
        guard
            let match = raw.wholeMatch(
                of: /<(\/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[^\s=>\/"']+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+))?)*)\s*\/?>/
            ),
            Self.tags.contains(match.2.lowercased())
        else { return nil }
        let name = match.2.lowercased()
        if !match.1.isEmpty { return ("</\(name)>", gt + 1) }
        var out = "<\(name)"
        let allowed = Self.everywhere.union(Self.attributes[name] ?? [])
        for attr in String(match.3).matches(of: /([^\s=>\/"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/) {
            let key = attr.1.lowercased()
            guard allowed.contains(key) else { continue }
            var value = String(attr.2 ?? attr.3 ?? attr.4 ?? "")
            if Self.urls.contains(key) { value = safe(value, image: name != "a") }
            out +=
                attr.2 == nil && attr.3 == nil && attr.4 == nil
                ? " \(key)" : " \(key)=\"\(MarkdownHTML.esc(value))\""
        }
        return (out + ">", gt + 1)
    }

    /// Raw HTML (a block, or a tag in a paragraph), its tags through the list, the rest as text.
    func sanitize(_ raw: String) -> String {
        let chars = Array(raw)
        var out = "", pos = 0
        while pos < chars.count {
            switch chars[pos] {
            case "<":
                if let (html, end) = htmlTag(chars, pos) {
                    out += html
                    pos = end
                } else if String(chars[pos...].prefix(4)) == "<!--",
                    let commentEnd = String(chars[pos...]).range(of: "-->")
                {
                    pos += String(chars[pos...])[..<commentEnd.upperBound].count
                } else {
                    out += "&lt;"
                    pos += 1
                }
            case ">":
                out += "&gt;"
                pos += 1
            case "&":
                let semicolon = chars[pos...].prefix(34).firstIndex(of: ";")
                let entity = semicolon.map { String(chars[pos...$0]) }
                if let entity,
                    entity.wholeMatch(of: /&(#[0-9]{1,7}|#x[0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/) != nil
                {
                    out += entity
                    pos += entity.count
                } else {
                    out += "&amp;"
                    pos += 1
                }
            default:
                out.append(chars[pos])
                pos += 1
            }
        }
        return out
    }

    // MARK: Alerts

    /// `> [!NOTE]` (TIP, IMPORTANT, WARNING, CAUTION) on a quote's first line: GitHub's colored box with its title.
    mutating func alert(_ quote: BlockQuote) -> String? {
        guard let first = quote.child(at: 0) as? Paragraph else { return nil }
        let line = Array(first.children.prefix { !($0 is SoftBreak || $0 is LineBreak) })
        let words = line.compactMap { ($0 as? Text)?.string }
        guard words.count == line.count,
            let match = words.joined().trimmingCharacters(in: .whitespaces)
                .wholeMatch(of: /\[!(?i)(note|tip|important|warning|caution)\]/)
        else { return nil }
        let kind = match.1.lowercased()
        let rest = inlines(first.children.dropFirst(line.count + 1))
        let blocks = (rest.isEmpty ? [] : ["<p>\(rest)</p>"]) + quote.children.dropFirst().map { visit($0) }
        return "<div class=\"markdown-alert markdown-alert-\(kind)\">\n<p class=\"markdown-alert-title\">"
            + "\(kind.capitalized)</p>\n\(blocks.joined(separator: "\n"))\n</div>"
    }

    // MARK: Footnotes

    /// Takes the footnote definitions (`[^label]: text` and the lines indented under it) out of the source into `notes`,
    /// blank lines in their place so the rest keeps its line numbers. Leading tabs are expanded on the way.
    mutating func takeNotes(_ md: String) -> String {
        var lines = md.split(separator: "\n", omittingEmptySubsequences: false).map { MarkdownHTML.detab(String($0)) }
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        var fence: Character?, i = 0
        while i < lines.count {
            let text = lines[i].drop { $0 == " " || $0 == ">" }
            if let mark = text.first, mark == "`" || mark == "~", text.prefix(while: { $0 == mark }).count >= 3 {
                if fence == nil {
                    fence = mark
                } else if mark == fence, text.drop(while: { $0 == mark }).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
            } else if fence == nil, indent(lines[i]) < 4,
                let match = lines[i].dropFirst(indent(lines[i])).prefixMatch(of: /\[\^([^\]\s]+)\]:[ \t]?/)
            {
                var end = i + 1
                while end < lines.count,
                    lines[end].allSatisfy(\.isWhitespace)
                        ? end + 1 < lines.count && indent(lines[end + 1]) >= 4 : indent(lines[end]) >= 4
                {
                    end += 1
                }
                let label = norm(String(match.1))
                if notes[label] == nil {
                    let more = lines[(i + 1)..<end].map { String($0.dropFirst(min(4, indent($0)))) }
                    notes[label] = ([String(lines[i][match.range.upperBound...])] + more).joined(separator: "\n")
                }
                for line in i..<end { lines[line] = "" }
                i = end
                continue
            }
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    /// `[^label]` with a definition: its number, linked to the note.
    mutating func footnoteRef(_ label: String) -> String? {
        let label = norm(label)
        guard notes[label] != nil else { return nil }
        if !noteOrder.contains(label) { noteOrder.append(label) }
        let number = (noteOrder.firstIndex(of: label) ?? 0) + 1
        return "<sup class=\"footnote-ref\"><a href=\"#fn-\(number)\" id=\"fnref-\(number)\">\(number)</a></sup>"
    }

    /// The notes referred to, numbered in the order of their first reference, each with a link back.
    mutating func footnotes() -> String {
        guard !noteOrder.isEmpty else { return "" }
        var html = "\n<section class=\"footnotes\">\n<ol>\n"
        var index = 0
        inNote = true
        while index < noteOrder.count {   // a note may refer to another, which joins the list
            let number = index + 1
            var body = blocks(Document(parsing: notes[noteOrder[index]] ?? "", options: .disableSmartOpts))
            let back = " <a href=\"#fnref-\(number)\" class=\"footnote-backref\">↩</a>"
            if body.hasSuffix("</p>") {
                body.insert(contentsOf: back, at: body.index(body.endIndex, offsetBy: -4))
            } else {
                body += back
            }
            html += "<li id=\"fn-\(number)\">\(body)</li>\n"
            index += 1
        }
        return html + "</ol>\n</section>"
    }

    // MARK: Text

    /// Plain text, escaped, its footnote references and bare links (`https://…`, `www.…` at a word's start) made links.
    mutating func text(_ text: String) -> String {
        guard !inLink else { return MarkdownHTML.esc(text) }
        var html = "", rest = text[...]
        while let match = rest.firstMatch(of: /\[\^([^\]]{1,100})\]|(?:https?:\/\/|www\.)[^\s<>"`]+/) {
            html += MarkdownHTML.esc(String(rest[..<match.range.lowerBound]))
            var end = match.range.upperBound
            if let label = match.1 {
                html += footnoteRef(String(label)) ?? MarkdownHTML.esc(String(match.0))
            } else if let url = bareLink(match.0, after: text[..<match.range.lowerBound].last) {
                let href = url.lowercased().hasPrefix("www.") ? "http://" + url : String(url)
                html += "<a href=\"\(MarkdownHTML.esc(href))\">\(MarkdownHTML.esc(String(url)))</a>"
                end = url.endIndex
            } else {
                html += MarkdownHTML.esc(String(match.0))
            }
            rest = rest[end...]
        }
        return html + MarkdownHTML.esc(String(rest))
    }

    /// The link in a bare `https://…` / `www.…` without the punctuation that ends a sentence; nil inside a word.
    private func bareLink(_ found: Substring, after previous: Character?) -> Substring? {
        guard previous.map({ $0.isWhitespace || "(*_~\"'".contains($0) }) ?? true else { return nil }
        var url = found
        while let last = url.last {
            let unmatched = last == ")" && url.filter { $0 == "(" }.count < url.filter { $0 == ")" }.count
            guard "?!.,:*_~'\";".contains(last) || unmatched else { break }
            url.removeLast()
        }
        let head = url.prefix(8).lowercased()
        return url.count > (head.hasPrefix("https://") ? 8 : head.hasPrefix("http://") ? 7 : 4) ? url : nil
    }

    /// Neutralises script-capable URL schemes.
    func safe(_ url: String, image: Bool = false) -> String {
        let lower = url.lowercased().filter { !$0.isWhitespace && !($0.asciiValue.map { $0 < 32 } ?? false) }
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:")
            || (lower.hasPrefix("data:") && !(image && lower.hasPrefix("data:image/")))
        {
            return "#"
        }
        return url
    }

    func stripTags(_ html: String) -> String {
        var out = "", tag = false
        for char in html {
            if char == "<" { tag = true } else if char == ">" { tag = false } else if !tag { out.append(char) }
        }
        return out
    }

    func norm(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
