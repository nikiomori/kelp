import Foundation

/// Dependency-free GitHub-flavoured Markdown → HTML.
/// Raw HTML is escaped, but for the tags and attributes on a list (MarkdownGFM): safety over fidelity.
public enum MarkdownHTML {
    public static func render(_ md: String) -> String {
        let src = md.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map { Line(s: detab(String($0))) }
        let r = Renderer()
        r.collectRefs(lines)
        return r.blocks(lines) + r.footnotes()
    }

    /// Full HTML document around `body`. `baseURL` (the document's URL) resolves relative links and images.
    /// `dark: true` forces the dark palette; otherwise `prefers-color-scheme` decides.
    /// Diagrams for ```mermaid blocks, drawn in the page with the bundled mermaid (no network); nil when there are none.
    public static func mermaid(for md: String, dark: Bool) -> String? {
        guard md.contains("```mermaid") || md.contains("~~~mermaid"), let js = mermaidJS else { return nil }
        return """
        <script>\(js)</script>
        <script>
        mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: '\(dark ? "dark" : "default")'});
        document.querySelectorAll('pre > code.language-mermaid').forEach(c => {
          const d = document.createElement('div'); d.className = 'mermaid'; d.textContent = c.textContent;
          c.parentElement.replaceWith(d);
        });
        mermaid.run().catch(() => {});   // a broken diagram shows mermaid's own error in its place
        </script>
        """
    }

    static let mermaidJS: String? = Bundle.module.url(forResource: "mermaid.min", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// `page`: the editor theme's background and text ("#rrggbb"), so a preview beside the editor sits on the same page.
    public static func page(body: String, baseURL: URL?, dark: Bool, page: (background: String, text: String)? = nil) -> String {
        let base = baseURL.map { "<base href=\"\(esc($0.absoluteString))\">\n" } ?? ""
        let theme = page.map { ":root,:root.dark{--bg:\(esc($0.background));--fg:\(esc($0.text))}" } ?? ""
        return """
        <!doctype html>
        <html\(dark ? " class=\"dark\"" : "")>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(dark ? "dark" : "light dark")">
        \(base)<style>\(css)\(theme)</style>
        </head>
        <body><article class="markdown-body">
        \(body)
        </article></body>
        </html>
        """
    }

    static let darkVars = "--fg:#f5f5f7;--muted:#a1a1a6;--bg:#1e1e1e;--border:#3d3d40;--subtle:#2a2a2d;--code:rgba(255,255,255,.09);--link:-webkit-link;"
        + "--note:#4493f8;--tip:#3fb950;--important:#ab7df8;--warning:#d29922;--caution:#f85149;"
    static let css = """
    :root{--fg:#1d1d1f;--muted:#6e6e73;--bg:#fff;--border:#d8d8dc;--subtle:#f5f5f7;--code:rgba(0,0,0,.055);--link:-webkit-link;
    --note:#0969da;--tip:#1a7f37;--important:#8250df;--warning:#9a6700;--caution:#cf222e;}
    @media (prefers-color-scheme:dark){:root{\(darkVars)}}
    :root.dark{\(darkVars)}
    *{box-sizing:border-box}
    html{background:var(--bg);color:var(--fg);-webkit-text-size-adjust:100%}
    body{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
    .markdown-body{max-width:860px;margin:0 auto;padding:32px 16px 64px;overflow-wrap:break-word}
    .markdown-body>:first-child{margin-top:0}
    h1,h2,h3,h4,h5,h6{margin:1.5em 0 .6em;font-weight:600;line-height:1.25}
    h1{font-size:2em;padding-bottom:.3em;border-bottom:1px solid var(--border)}
    h2{font-size:1.5em;padding-bottom:.3em;border-bottom:1px solid var(--border)}
    h3{font-size:1.25em}h4{font-size:1em}h5{font-size:.875em}h6{font-size:.85em;color:var(--muted)}
    p,blockquote,ul,ol,table,pre{margin:0 0 16px}
    a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}
    strong{font-weight:600}del{color:var(--muted)}
    hr{height:1px;border:0;background:var(--border);margin:24px 0}
    blockquote{padding:0 1em;color:var(--muted);border-left:.25em solid var(--border)}
    blockquote>:last-child{margin-bottom:0}
    ul,ol{padding-left:2em}
    li+li{margin-top:.25em}
    li>ul,li>ol{margin:.25em 0 0}
    li>p{margin:.5em 0}
    .task-list-item{list-style:none}
    .task-list-item input{margin:0 .4em .2em -1.5em;vertical-align:middle}
    code,pre{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;font-size:85%}
    code{padding:.2em .4em;border-radius:6px;background:var(--code)}
    pre{padding:16px;overflow:auto;line-height:1.45;border-radius:8px;background:var(--subtle)}
    pre code{padding:0;background:none;font-size:100%}
    table{border-collapse:collapse;display:block;width:max-content;max-width:100%;overflow:auto}
    th,td{padding:6px 13px;border:1px solid var(--border)}
    th{font-weight:600}
    tbody tr:nth-child(2n){background:var(--subtle)}
    img{max-width:100%}
    details{margin:0 0 16px}summary{cursor:pointer}details>:not(summary){margin-top:8px}
    kbd{display:inline-block;padding:.1em .45em;font:80% ui-monospace,"SF Mono",Menlo,monospace;line-height:1.4;border:1px solid var(--border);
    border-bottom-width:2px;border-radius:5px;background:var(--subtle)}
    sup{line-height:0}
    .markdown-alert{padding:.5em 1em;margin:0 0 16px;border-left:.25em solid var(--al)}
    .markdown-alert>:last-child{margin-bottom:0}
    .markdown-alert-title{font-weight:600;color:var(--al);margin:0 0 .3em}
    .markdown-alert-note{--al:var(--note)}.markdown-alert-tip{--al:var(--tip)}.markdown-alert-important{--al:var(--important)}
    .markdown-alert-warning{--al:var(--warning)}.markdown-alert-caution{--al:var(--caution)}
    .footnotes{margin-top:32px;padding-top:12px;border-top:1px solid var(--border);font-size:.875em;color:var(--muted)}
    .footnotes li{margin-top:.4em}.footnote-backref{margin-left:.2em}
    """

    /// Safe in text and in double-quoted attributes (the only kind Kelp's pages write).
    static func esc(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default: o.append(c)
            }
        }
        return o
    }

    /// Expands leading tabs to 4-column stops; tabs elsewhere are kept.
    static func detab(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        var o = "", col = 0, leading = true
        for c in s {
            if leading, c == "\t" { let n = 4 - col % 4; o += String(repeating: " ", count: n); col += n; continue }
            if c != " " { leading = false }
            o.append(c); col += 1
        }
        return o
    }
}

struct Line {
    var s: String
    var blank: Bool { s.allSatisfy(\.isWhitespace) }
    var indent: Int { s.prefix { $0 == " " }.count }
    func dropping(_ k: Int) -> Line { Line(s: String(s.dropFirst(min(k, indent)))) }
}

struct Marker {
    let indent: Int, kind: Character, ordered: Bool, start: Int, content: Int, rest: String
}

struct Delim {
    let ch: Character, orig: Int
    var count: Int, open: Bool, close: Bool
    var pre: [String] = [], post: [String] = []
}

enum Node { case html(String), delim(Delim) }

final class Renderer {
    var refs: [String: (url: String, title: String?)] = [:]
    var slugs: [String: Int] = [:]
    /// Footnotes by label, and the order they're first referred to in (their numbers).
    var notes: [String: [Line]] = [:]
    var noteOrder: [String] = []

    // MARK: blocks

    func collectRefs(_ ls: [Line]) {
        var fenceCh: Character?
        for (i, l) in ls.enumerated() {
            let s = String(l.s.drop { $0 == " " || $0 == ">" })
            if let f = fence(s) {
                if fenceCh == nil { fenceCh = f.ch } else if f.ch == fenceCh, f.info.isEmpty { fenceCh = nil }
            } else if fenceCh == nil, l.indent < 4, footnote(s) != nil {
                collectFootnote(ls, i)
            } else if fenceCh == nil, let d = def(s), refs[d.label] == nil {
                refs[d.label] = (d.url, d.title)
            }
        }
    }

    func blocks(_ ls: [Line], tight: Bool = false) -> String {
        var out: [String] = [], i = 0
        while i < ls.count {
            let l = ls[i], ind = l.indent
            if l.blank { i += 1; continue }
            let s = String(l.s.dropFirst(ind))
            let block: (html: String?, end: Int)
            if ind >= 4 { block = indentedCode(ls, i) }
            else if let f = fence(s) { block = fencedCode(ls, i, f) }
            else if let h = atx(s) { block = (heading(h.0, h.1), i + 1) }
            else if isHR(s) { block = ("<hr>", i + 1) }
            else if s.hasPrefix(">") { block = blockquote(ls, i) }
            else if let m = marker(l.s) { block = list(ls, i, m) }
            else if isTable(ls, i) { block = table(ls, i) }
            else if footnote(s) != nil { block = (nil, footnoteEnd(ls, i)) }   // read already: shown at the end
            else if def(s) != nil { block = (nil, i + 1) }   // a link reference definition: read already, shows nothing
            else if startsHTML(s) { block = htmlBlock(ls, i) }
            else { block = paragraph(ls, i, tight: tight) }
            if let html = block.html { out.append(html) }
            i = block.end
        }
        return out.joined(separator: "\n")
    }

    // Each reads the block that starts at ls[i] and returns its HTML and the line after it.

    private func indentedCode(_ ls: [Line], _ i: Int) -> (String?, Int) {
        var body: [String] = [], j = i
        while j < ls.count, ls[j].blank || ls[j].indent >= 4 { body.append(String(ls[j].s.dropFirst(4))); j += 1 }
        while body.last?.allSatisfy(\.isWhitespace) == true { body.removeLast() }
        return ("<pre><code>\(MarkdownHTML.esc(body.joined(separator: "\n")))\n</code></pre>", j)
    }

    private func fencedCode(_ ls: [Line], _ i: Int, _ f: (ch: Character, len: Int, info: String)) -> (String?, Int) {
        let ind = ls[i].indent
        var body: [String] = [], j = i + 1
        while j < ls.count {
            let x = ls[j]
            if x.indent < 4, let c = fence(String(x.s.dropFirst(x.indent))), c.ch == f.ch, c.len >= f.len, c.info.isEmpty { j += 1; break }
            body.append(x.dropping(ind).s); j += 1
        }
        let lang = f.info.split(separator: " ").first.map { " class=\"language-\(MarkdownHTML.esc(String($0)))\"" } ?? ""
        let code = body.isEmpty ? "" : MarkdownHTML.esc(body.joined(separator: "\n")) + "\n"
        return ("<pre><code\(lang)>\(code)</code></pre>", j)
    }

    private func blockquote(_ ls: [Line], _ i: Int) -> (String?, Int) {
        var inner: [Line] = [], j = i
        while j < ls.count {
            let x = ls[j], xs = x.s.dropFirst(min(x.indent, 3))
            if x.indent < 4, xs.hasPrefix(">") {
                var rest = xs.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                inner.append(Line(s: String(rest)))
            } else if !x.blank, inner.last?.blank == false, !interrupts(x.s) {
                inner.append(x) // lazy continuation
            } else { break }
            j += 1
        }
        return (alert(inner) ?? "<blockquote>\n\(blocks(inner))\n</blockquote>", j)
    }

    /// A paragraph, or a setext heading when an `===` / `---` line ends it.
    private func paragraph(_ ls: [Line], _ i: Int, tight: Bool) -> (String?, Int) {
        var text: [String] = [], j = i, setext = 0
        while j < ls.count {
            let x = ls[j]
            if x.blank { break }
            if j > i {
                let t = x.s.trimmingCharacters(in: .whitespaces)
                if x.indent < 4, let c = t.first, c == "=" || c == "-", t.allSatisfy({ $0 == c }) { setext = c == "=" ? 1 : 2; j += 1; break }
                if interrupts(x.s) || isTable(ls, j) { break }
            }
            text.append(String(x.s.drop { $0 == " " })); j += 1
        }
        let raw = text.joined(separator: "\n").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        if setext > 0 { return (heading(setext, raw), j) }
        let body = inline(raw)
        return (body.isEmpty ? nil : tight ? body : "<p>\(body)</p>", j)
    }

    private func heading(_ level: Int, _ raw: String) -> String {
        let html = inline(raw)
        var base = ""
        for c in stripTags(html).replacing(/&#?\w+;/, with: "").lowercased() {
            if c.isLetter || c.isNumber || c == "-" || c == "_" { base.append(c) } else if c == " " { base.append("-") }
        }
        let k = slugs[base, default: 0]
        slugs[base] = k + 1
        let id = k == 0 ? base : "\(base)-\(k)"
        return "<h\(level) id=\"\(MarkdownHTML.esc(id))\">\(html)</h\(level)>"
    }

    private func list(_ ls: [Line], _ i: Int, _ m0: Marker) -> (String, Int) {
        var items: [[Line]] = [], j = i, cur = m0, loose = false
        while true {
            var body = [Line(s: cur.rest)]
            j += 1
            while j < ls.count {
                let x = ls[j]
                if x.blank { body.append(Line(s: "")) }
                else if x.indent >= cur.content { body.append(x.dropping(cur.content)) }
                else if marker(x.s) == nil, body.last?.blank == false, !interrupts(x.s) { body.append(x) } // lazy
                else { break }
                j += 1
            }
            var trailing = 0
            while body.count > 1, body.last?.blank == true { body.removeLast(); trailing += 1 }
            // Limit: blank line followed by an unindented line inside an item counts as loose; fenced code with blank lines can false-positive.
            if zip(body, body.dropFirst()).contains(where: { $0.blank && !$1.blank && $1.indent == 0 }) { loose = true }
            items.append(body)
            guard j < ls.count, let nm = marker(ls[j].s), nm.kind == m0.kind,
                  !isHR(String(ls[j].s.dropFirst(ls[j].indent))) else { break }
            if trailing > 0 { loose = true }
            cur = nm
        }
        let tag = m0.ordered ? "ol" : "ul"
        let start = m0.ordered && m0.start != 1 ? " start=\"\(m0.start)\"" : ""
        var html = "<\(tag)\(start)>\n"
        for var body in items {
            var box = ""
            let first = body[0].s
            if first.hasPrefix("[ ]") || first.hasPrefix("[x]") || first.hasPrefix("[X]"), first.count == 3 || first.dropFirst(3).first == " " {
                box = "<input type=\"checkbox\" disabled\(first.hasPrefix("[ ]") ? "" : " checked")> "
                body[0].s = String(first.dropFirst(4))
            }
            var inner = blocks(body, tight: !loose)
            if !box.isEmpty {
                if inner.hasPrefix("<p"), let gt = inner.firstIndex(of: ">") {
                    inner.insert(contentsOf: box, at: inner.index(after: gt))
                } else {
                    inner = box + inner
                }
            }
            html += "<li\(box.isEmpty ? "" : " class=\"task-list-item\"")>\(inner)</li>\n"
        }
        return (html + "</\(tag)>", j)
    }

    private func cells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = [], cur = "", prev: Character = " "
        for c in t {
            if c == "|", prev != "\\" { out.append(cur); cur = "" } else if c == "|" { cur.removeLast(); cur.append(c) } else { cur.append(c) }
            prev = c
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func aligns(_ s: String) -> [String]? {
        guard s.contains("|") else { return nil }
        var out: [String] = []
        for c in cells(s) {
            var d = Substring(c)
            if d.first == ":" { d = d.dropFirst() }
            if d.last == ":" { d = d.dropLast() }
            guard !d.isEmpty, d.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(c.hasPrefix(":") && c.hasSuffix(":") ? "center" : c.hasSuffix(":") ? "right" : c.hasPrefix(":") ? "left" : "")
        }
        return out
    }

    private func isTable(_ ls: [Line], _ i: Int) -> Bool {
        guard i + 1 < ls.count, ls[i].indent < 4, ls[i].s.contains("|"), let a = aligns(ls[i + 1].s) else { return false }
        return a.count == cells(ls[i].s).count
    }

    private func table(_ ls: [Line], _ i: Int) -> (String, Int) {
        let al = aligns(ls[i + 1].s) ?? []
        func row(_ l: Line, _ tag: String) -> String {
            let cs = cells(l.s)
            let tds = al.indices.map { k in
                let style = al[k].isEmpty ? "" : " style=\"text-align:\(al[k])\""
                return "<\(tag)\(style)>\(k < cs.count ? inline(cs[k]) : "")</\(tag)>"
            }
            return "<tr>\(tds.joined())</tr>"
        }
        var html = "<table>\n<thead>\n\(row(ls[i], "th"))\n</thead>\n"
        var j = i + 2, body: [String] = []
        while j < ls.count, !ls[j].blank, ls[j].s.contains("|"), !interrupts(ls[j].s) { body.append(row(ls[j], "td")); j += 1 }
        if !body.isEmpty { html += "<tbody>\n\(body.joined(separator: "\n"))\n</tbody>\n" }
        return (html + "</table>", j)
    }

    private func fence(_ s: String) -> (ch: Character, len: Int, info: String)? {
        guard let c = s.first, c == "`" || c == "~" else { return nil }
        let len = s.prefix { $0 == c }.count
        let info = s.dropFirst(len).trimmingCharacters(in: .whitespaces)
        guard len >= 3, c == "~" || !info.contains("`") else { return nil }
        return (c, len, info)
    }

    private func atx(_ s: String) -> (Int, String)? {
        let level = s.prefix { $0 == "#" }.count
        let rest = s.dropFirst(level)
        guard (1...6).contains(level), rest.isEmpty || rest.first == " " else { return nil }
        var t = rest.trimmingCharacters(in: .whitespaces)
        if let k = t.lastIndex(where: { $0 != "#" }) {
            if t[k] == " " { t = String(t[...k]).trimmingCharacters(in: .whitespaces) }
        } else { t = "" }
        return (level, t)
    }

    private func isHR(_ s: String) -> Bool {
        guard let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c || $0 == " " || $0 == "\t" } && s.filter { $0 == c }.count >= 3
    }

    private func marker(_ t: String) -> Marker? {
        let ind = t.prefix { $0 == " " }.count
        guard ind < 4 else { return nil }
        let s = Array(t.dropFirst(ind))
        var k = 0, ordered = false, start = 0
        guard let c0 = s.first else { return nil }
        var kind = c0
        if "-*+".contains(c0) { k = 1 } else {
            while k < s.count, k < 9, s[k].isASCII, s[k].isNumber { k += 1 }
            guard k > 0, k < s.count, s[k] == "." || s[k] == ")", let v = Int(String(s[0..<k])) else { return nil }
            kind = s[k]; start = v; ordered = true; k += 1
        }
        guard k == s.count || s[k] == " " else { return nil }
        let sp = s[k...].prefix { $0 == " " }.count
        let rest = String(s[(k + sp)...])
        if rest.isEmpty || sp > 4 {
            return Marker(indent: ind, kind: kind, ordered: ordered, start: start, content: ind + k + 1,
                          rest: rest.isEmpty ? "" : String(s[min(k + 1, s.count)...]))
        }
        return Marker(indent: ind, kind: kind, ordered: ordered, start: start, content: ind + k + sp, rest: rest)
    }

    /// Lines that end a paragraph (and so can't be lazy continuations).
    private func interrupts(_ t: String) -> Bool {
        let ind = t.prefix { $0 == " " }.count
        guard ind < 4 else { return false }
        let s = String(t.dropFirst(ind))
        if fence(s) != nil || atx(s) != nil || isHR(s) || s.hasPrefix(">") || startsHTML(s, interrupting: true) { return true }
        if let m = marker(t), !m.rest.isEmpty, !m.ordered || m.start == 1 { return true }
        return false
    }

    private func def(_ s: String) -> (label: String, url: String, title: String?)? {
        guard s.hasPrefix("["), s.contains("]:"), let m = s.wholeMatch(of: /\[([^\]]+)\]:\s*<?([^\s>]+)>?(?:\s+["'(](.*)["')])?\s*/) else { return nil }
        return (norm(String(m.1)), String(m.2), m.3.map(String.init))
    }

    func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: inline

}
