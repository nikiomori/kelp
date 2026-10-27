import Foundation

/// What GitHub adds to Markdown that READMEs use: alerts (`> [!NOTE]`), footnotes (`[^1]`) and the safe part of HTML
/// (`<details>`, `<kbd>`, `<img width>`, `<picture>`…), tag by tag and attribute by attribute from a list: no script,
/// no style, no event handler, no `javascript:` link.
extension Renderer {
    // MARK: HTML

    private static let tags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "center", "cite", "code", "dd", "del", "details", "div", "dl", "dt", "em", "h1", "h2", "h3",
        "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "picture", "pre", "q", "s", "samp", "small", "source", "span",
        "strike", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "u", "ul", "var"
    ]
    /// Tags that start an HTML block (and end a paragraph).
    private static let blockTags: Set<String> = [
        "blockquote", "center", "details", "div", "dl", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "ol", "p", "picture", "pre", "summary", "table", "ul"
    ]
    private static let attributes: [String: Set<String>] = [
        "a": ["href", "name"], "img": ["src", "alt", "width", "height"], "source": ["srcset", "media", "type"], "details": ["open"],
        "td": ["colspan", "rowspan"], "th": ["colspan", "rowspan"], "ol": ["start", "type"], "li": ["value"]
    ]
    private static let everywhere: Set<String> = ["align", "title", "dir", "lang"]
    private static let urls: Set<String> = ["href", "src", "srcset"]

    /// A whole tag at `c[i]` whose name is on the list, written back with only the attributes on the list.
    func htmlTag(_ c: [Character], _ i: Int) -> (String, Int)? {
        guard let gt = c[i...].prefix(1000).firstIndex(of: ">") else { return nil }
        let raw = String(c[i...gt])
        guard let m = raw.wholeMatch(of: /<(\/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[^\s=>\/"']+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+))?)*)\s*\/?>/),
              Self.tags.contains(m.2.lowercased()) else { return nil }
        let name = m.2.lowercased()
        if !m.1.isEmpty { return ("</\(name)>", gt + 1) }
        var out = "<\(name)"
        let allowed = Self.everywhere.union(Self.attributes[name] ?? [])
        for a in String(m.3).matches(of: /([^\s=>\/"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/) {
            let key = a.1.lowercased()
            guard allowed.contains(key) else { continue }
            var value = String(a.2 ?? a.3 ?? a.4 ?? "")
            if Self.urls.contains(key) { value = safe(value, image: name != "a") }
            out += a.2 == nil && a.3 == nil && a.4 == nil ? " \(key)" : " \(key)=\"\(MarkdownHTML.esc(value))\""
        }
        return (out + ">", gt + 1)
    }

    /// A line that starts an HTML block: a block tag on the list at its start, or (not ending a paragraph) any tag on
    /// the list alone on it — `<b>Note:</b> *text*` stays a paragraph, with its Markdown.
    func startsHTML(_ s: String, interrupting: Bool = false) -> Bool {
        guard s.first == "<", let m = s.prefixMatch(of: /<\/?([A-Za-z][A-Za-z0-9]*)(?:[\s>\/]|$)/) else { return false }
        let name = m.1.lowercased()
        if Self.blockTags.contains(name) { return true }
        let t = Array(s.trimmingCharacters(in: .whitespaces))
        return !interrupting && htmlTag(t, 0)?.1 == t.count
    }

    /// An HTML block: lines up to a blank one, as HTML (no Markdown inside), its tags through the list.
    func htmlBlock(_ ls: [Line], _ i: Int) -> (String, Int) {
        var j = i, text: [String] = []
        while j < ls.count, !ls[j].blank { text.append(ls[j].s); j += 1 }
        let c = Array(text.joined(separator: "\n"))
        var out = "", k = 0
        while k < c.count {
            switch c[k] {
            case "<":
                if let (html, end) = htmlTag(c, k) { out += html; k = end } else if String(c[k...].prefix(4)) == "<!--",
                    let r = String(c[k...]).range(of: "-->") { k += String(c[k...])[..<r.upperBound].count } else { out += "&lt;"; k += 1 }
            case ">": out += "&gt;"; k += 1
            case "&":
                let e = c[k...].prefix(34).firstIndex(of: ";")
                let entity = e.map { String(c[k...$0]) }
                if let entity, entity.wholeMatch(of: /&(#[0-9]{1,7}|#x[0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/) != nil {
                    out += entity; k += entity.count
                } else { out += "&amp;"; k += 1 }
            default: out.append(c[k]); k += 1
            }
        }
        return (out, j)
    }

    // MARK: Alerts

    /// `> [!NOTE]` (TIP, IMPORTANT, WARNING, CAUTION) on a quote's first line: GitHub's colored box with its title.
    func alert(_ inner: [Line]) -> String? {
        guard let first = inner.first, let m = first.s.trimmingCharacters(in: .whitespaces)
                .wholeMatch(of: /\[!(?i)(note|tip|important|warning|caution)\]/) else { return nil }
        let kind = m.1.lowercased()
        return "<div class=\"markdown-alert markdown-alert-\(kind)\">\n<p class=\"markdown-alert-title\">\(kind.capitalized)</p>\n"
            + blocks(Array(inner.dropFirst())) + "\n</div>"
    }

    // MARK: Footnotes

    /// `[^label]: text` and the lines indented under it.
    func footnote(_ s: String) -> (label: String, text: String)? {
        guard s.hasPrefix("[^"), let m = s.prefixMatch(of: /\[\^([^\]\s]+)\]:[ \t]?/) else { return nil }
        return (norm(String(m.1)), String(s[m.range.upperBound...]))
    }

    /// The footnote definition at ls[i] read (in `collectRefs`) or skipped (in `blocks`): where the next block starts.
    func footnoteEnd(_ ls: [Line], _ i: Int) -> Int {
        var j = i + 1
        while j < ls.count, ls[j].blank ? (j + 1 < ls.count && ls[j + 1].indent >= 4) : ls[j].indent >= 4 { j += 1 }
        return j
    }

    func collectFootnote(_ ls: [Line], _ i: Int) {
        guard let (label, text) = footnote(String(ls[i].s.dropFirst(ls[i].indent))), notes[label] == nil else { return }
        notes[label] = [Line(s: text)] + ls[(i + 1)..<footnoteEnd(ls, i)].map { $0.dropping(4) }
    }

    /// `[^label]` with a definition: its number, linked to the note.
    func footnoteRef(_ c: [Character], _ i: Int) -> (String, Int)? {
        guard i + 2 < c.count, c[i + 1] == "^", let close = c[(i + 2)...].prefix(100).firstIndex(of: "]") else { return nil }
        let label = norm(String(c[(i + 2)..<close]))
        guard notes[label] != nil else { return nil }
        if !noteOrder.contains(label) { noteOrder.append(label) }
        let n = (noteOrder.firstIndex(of: label) ?? 0) + 1
        return ("<sup class=\"footnote-ref\"><a href=\"#fn-\(n)\" id=\"fnref-\(n)\">\(n)</a></sup>", close + 1)
    }

    /// The notes referred to, numbered in the order of their first reference, each with a link back.
    func footnotes() -> String {
        guard !noteOrder.isEmpty else { return "" }
        var html = "\n<section class=\"footnotes\">\n<ol>\n"
        var k = 0
        while k < noteOrder.count {   // a note may refer to another, which joins the list
            let n = k + 1
            var body = blocks(notes[noteOrder[k]] ?? [], tight: true)
            let back = " <a href=\"#fnref-\(n)\" class=\"footnote-backref\">↩</a>"
            if body.hasSuffix("</p>") { body.insert(contentsOf: back, at: body.index(body.endIndex, offsetBy: -4)) } else { body += back }
            html += "<li id=\"fn-\(n)\">\(body)</li>\n"
            k += 1
        }
        return html + "</ol>\n</section>"
    }
}
