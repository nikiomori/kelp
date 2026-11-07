import Foundation

/// What GitHub adds to Markdown that READMEs use: alerts (`> [!NOTE]`), footnotes (`[^1]`) and the safe part of HTML
/// (`<details>`, `<kbd>`, `<img width>`, `<picture>`…), tag by tag and attribute by attribute from a list: no script,
/// no style, no event handler, no `javascript:` link.
extension Renderer {
    // MARK: HTML

    private static let tags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "center", "cite", "code", "dd", "del", "details", "div", "dl", "dt", "em",
        "h1", "h2", "h3",
        "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "picture", "pre", "q", "s", "samp",
        "small", "source", "span",
        "strike", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "u", "ul",
        "var"
    ]
    /// Tags that start an HTML block (and end a paragraph).
    private static let blockTags: Set<String> = [
        "blockquote", "center", "details", "div", "dl", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "ol", "p", "picture",
        "pre", "summary", "table", "ul"
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

    /// A line that starts an HTML block: a block tag on the list at its start, or (not ending a paragraph) any tag on
    /// the list alone on it — `<b>Note:</b> *text*` stays a paragraph, with its Markdown.
    func startsHTML(_ line: String, interrupting: Bool = false) -> Bool {
        guard line.first == "<", let match = line.prefixMatch(of: /<\/?([A-Za-z][A-Za-z0-9]*)(?:[\s>\/]|$)/) else {
            return false
        }
        let name = match.1.lowercased()
        if Self.blockTags.contains(name) { return true }
        let chars = Array(line.trimmingCharacters(in: .whitespaces))
        return !interrupting && htmlTag(chars, 0)?.1 == chars.count
    }

    /// An HTML block: lines up to a blank one, as HTML (no Markdown inside), its tags through the list.
    func htmlBlock(_ ls: [Line], _ i: Int) -> (String, Int) {
        var next = i, text: [String] = []
        while next < ls.count, !ls[next].blank {
            text.append(ls[next].text)
            next += 1
        }
        let chars = Array(text.joined(separator: "\n"))
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
        return (out, next)
    }

    // MARK: Alerts

    /// `> [!NOTE]` (TIP, IMPORTANT, WARNING, CAUTION) on a quote's first line: GitHub's colored box with its title.
    func alert(_ inner: [Line]) -> String? {
        guard let first = inner.first,
            let match = first.text.trimmingCharacters(in: .whitespaces)
                .wholeMatch(of: /\[!(?i)(note|tip|important|warning|caution)\]/)
        else { return nil }
        let kind = match.1.lowercased()
        return
            "<div class=\"markdown-alert markdown-alert-\(kind)\">\n<p class=\"markdown-alert-title\">\(kind.capitalized)</p>\n"
            + blocks(Array(inner.dropFirst())) + "\n</div>"
    }

    // MARK: Footnotes

    /// `[^label]: text` and the lines indented under it.
    func footnote(_ line: String) -> (label: String, text: String)? {
        guard line.hasPrefix("[^"), let match = line.prefixMatch(of: /\[\^([^\]\s]+)\]:[ \t]?/) else { return nil }
        return (norm(String(match.1)), String(line[match.range.upperBound...]))
    }

    /// The footnote definition at ls[i] read (in `collectRefs`) or skipped (in `blocks`): where the next block starts.
    func footnoteEnd(_ ls: [Line], _ i: Int) -> Int {
        var end = i + 1
        while end < ls.count, ls[end].blank ? (end + 1 < ls.count && ls[end + 1].indent >= 4) : ls[end].indent >= 4 {
            end += 1
        }
        return end
    }

    func collectFootnote(_ ls: [Line], _ i: Int) {
        guard let (label, text) = footnote(String(ls[i].text.dropFirst(ls[i].indent))), notes[label] == nil else {
            return
        }
        notes[label] = [Line(text: text)] + ls[(i + 1)..<footnoteEnd(ls, i)].map { $0.dropping(4) }
    }

    /// `[^label]` with a definition: its number, linked to the note.
    func footnoteRef(_ c: [Character], _ i: Int) -> (String, Int)? {
        guard i + 2 < c.count, c[i + 1] == "^", let close = c[(i + 2)...].prefix(100).firstIndex(of: "]") else {
            return nil
        }
        let label = norm(String(c[(i + 2)..<close]))
        guard notes[label] != nil else { return nil }
        if !noteOrder.contains(label) { noteOrder.append(label) }
        let number = (noteOrder.firstIndex(of: label) ?? 0) + 1
        return (
            "<sup class=\"footnote-ref\"><a href=\"#fn-\(number)\" id=\"fnref-\(number)\">\(number)</a></sup>",
            close + 1
        )
    }

    /// The notes referred to, numbered in the order of their first reference, each with a link back.
    func footnotes() -> String {
        guard !noteOrder.isEmpty else { return "" }
        var html = "\n<section class=\"footnotes\">\n<ol>\n"
        var index = 0
        while index < noteOrder.count {   // a note may refer to another, which joins the list
            let number = index + 1
            var body = blocks(notes[noteOrder[index]] ?? [], tight: true)
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
}
