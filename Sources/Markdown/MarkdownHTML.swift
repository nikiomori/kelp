import Foundation

/// Dependency-free GitHub-flavoured Markdown → HTML.
/// Raw HTML is escaped, but for the tags and attributes on a list (MarkdownGFM): safety over fidelity.
public enum MarkdownHTML {
    /// `marking`: each top-level block goes after an invisible mark of its source line, for `scrollSync` to go by.
    public static func render(_ md: String, marking: Bool = false) -> String {
        let src = md.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map { Line(text: detab(String($0))) }
        let renderer = Renderer()
        renderer.collectRefs(lines)
        return renderer.blocks(lines, marking: marking) + renderer.footnotes()
    }

    /// Keeps a preview with its source: `kelpToLine(n)` scrolls to source line `n`, between the marks around it; scrolling
    /// and double-clicking post the line to the `kelpSync` handler. A scroll it did itself doesn't echo back. JavaScript, run
    /// beside the page (`MarkdownTab.world`), as all of Kelp's scripts for a preview are.
    public static let scrollSync = """
        (function () {
          const marks = () => [...document.querySelectorAll('[data-line]')].map(e => ({ l: +e.dataset.line, y: e.getBoundingClientRect().top + scrollY }));
          const between = (list, get, v) => {
            let a = list[0], b = null;
            for (const m of list) { if (get(m) <= v) a = m; else { b = m; break; } }
            return [a, b];
          };
          let quiet = 0;
          window.kelpToLine = n => {
            const [a, b] = between(marks(), m => m.l, n);
            if (!a) return;
            quiet = Date.now() + 200;
            scrollTo(0, a.y + (b ? (b.y - a.y) * (n - a.l) / (b.l - a.l) : 0));
          };
          const lineAt = y => {
            const [a, b] = between(marks(), m => m.y, y);
            if (!a) return 1;
            return Math.round(a.l + (b && b.y > a.y ? (b.l - a.l) * (y - a.y) / (b.y - a.y) : 0));
          };
          const post = (kind, line) => webkit.messageHandlers.kelpSync?.postMessage({ kind, line });
          addEventListener('scroll', () => { if (Date.now() > quiet) post('scroll', lineAt(scrollY)); }, { passive: true });
          addEventListener('dblclick', e => post('open', lineAt(e.clientY + scrollY)));
        })();
        """

    /// Full HTML document around `body`. `baseURL` (the document's URL) resolves relative links and images.
    /// `dark: true` forces the dark palette; otherwise `prefers-color-scheme` decides.
    /// Diagrams for ```mermaid blocks, drawn in the page with the bundled mermaid (no network); nil when there are none.
    /// JavaScript, as `scrollSync`.
    public static func mermaid(for md: String, dark: Bool) -> String? {
        guard md.contains("```mermaid") || md.contains("~~~mermaid"), let js = mermaidJS else { return nil }
        return js + """

            mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: '\(dark ? "dark" : "default")'});
            document.querySelectorAll('pre > code.language-mermaid').forEach(c => {
              const d = document.createElement('div'); d.className = 'mermaid'; d.textContent = c.textContent;
              c.parentElement.replaceWith(d);
            });
            mermaid.run().catch(() => {});   // a broken diagram shows mermaid's own error in its place
            """
    }

    static let mermaidJS: String? = Bundle.module.url(forResource: "mermaid.min", withExtension: "js").flatMap {
        try? String(contentsOf: $0, encoding: .utf8)
    }

    /// `page`: the editor theme's background and text ("#rrggbb"), so a preview beside the editor sits on the same page.
    public static func page(body: String, baseURL: URL?, dark: Bool, page: (background: String, text: String)? = nil)
        -> String
    {
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

    static let darkVars =
        "--fg:#f5f5f7;--muted:#a1a1a6;--bg:#1e1e1e;--border:#3d3d40;--subtle:#2a2a2d;--code:rgba(255,255,255,.09);--link:-webkit-link;"
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
        .markdown-body>:first-child,.markdown-body>[data-line]:first-child+*{margin-top:0}
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
    static func esc(_ text: String) -> String {
        var out = ""
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(char)
            }
        }
        return out
    }

    /// Expands leading tabs to 4-column stops; tabs elsewhere are kept.
    static func detab(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var out = "", col = 0, leading = true
        for char in line {
            if leading, char == "\t" {
                let spaces = 4 - col % 4
                out += String(repeating: " ", count: spaces)
                col += spaces
                continue
            }
            if char != " " { leading = false }
            out.append(char)
            col += 1
        }
        return out
    }
}

struct Line {
    var text: String
    var blank: Bool { text.allSatisfy(\.isWhitespace) }
    var indent: Int { text.prefix { $0 == " " }.count }
    func dropping(_ count: Int) -> Line { Line(text: String(text.dropFirst(min(count, indent)))) }
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
        for (i, line) in ls.enumerated() {
            let text = String(line.text.drop { $0 == " " || $0 == ">" })
            if let opening = fence(text) {
                if fenceCh == nil {
                    fenceCh = opening.ch
                } else if opening.ch == fenceCh, opening.info.isEmpty {
                    fenceCh = nil
                }
            } else if fenceCh == nil, line.indent < 4, footnote(text) != nil {
                collectFootnote(ls, i)
            } else if fenceCh == nil, let ref = def(text), refs[ref.label] == nil {
                refs[ref.label] = (ref.url, ref.title)
            }
        }
    }

    func blocks(_ ls: [Line], tight: Bool = false, marking: Bool = false) -> String {
        var out: [String] = [], i = 0
        while i < ls.count {
            let line = ls[i], ind = line.indent
            if line.blank {
                i += 1
                continue
            }
            let text = String(line.text.dropFirst(ind))
            let block: (html: String?, end: Int)
            if ind >= 4 {
                block = indentedCode(ls, i)
            } else if let opening = fence(text) {
                block = fencedCode(ls, i, opening)
            } else if let atxHeading = atx(text) {
                block = (heading(atxHeading.0, atxHeading.1), i + 1)
            } else if isHR(text) {
                block = ("<hr>", i + 1)
            } else if text.hasPrefix(">") {
                block = blockquote(ls, i)
            } else if let listMarker = marker(line.text) {
                block = list(ls, i, listMarker)
            } else if isTable(ls, i) {
                block = table(ls, i)
            } else if footnote(text) != nil {
                block = (nil, footnoteEnd(ls, i))
            }   // read already: shown at the end
            else if def(text) != nil {
                block = (nil, i + 1)
            }   // a link reference definition: read already, shows nothing
            else if startsHTML(text) {
                block = htmlBlock(ls, i)
            } else {
                block = paragraph(ls, i, tight: tight)
            }
            if let html = block.html {
                out.append(marking ? "<i data-line=\"\(i + 1)\" style=\"display:block;height:0\"></i>\n" + html : html)
            }
            i = block.end
        }
        return out.joined(separator: "\n")
    }

    // Each reads the block that starts at ls[i] and returns its HTML and the line after it.

    private func indentedCode(_ ls: [Line], _ i: Int) -> (String?, Int) {
        var body: [String] = [], j = i
        while j < ls.count, ls[j].blank || ls[j].indent >= 4 {
            body.append(String(ls[j].text.dropFirst(4)))
            j += 1
        }
        while body.last?.allSatisfy(\.isWhitespace) == true { body.removeLast() }
        return ("<pre><code>\(MarkdownHTML.esc(body.joined(separator: "\n")))\n</code></pre>", j)
    }

    private func fencedCode(
        _ ls: [Line], _ i: Int, _ opening: (ch: Character, len: Int, info: String)
    ) -> (String?, Int) {
        let ind = ls[i].indent
        var body: [String] = [], j = i + 1
        while j < ls.count {
            let line = ls[j]
            if line.indent < 4, let closing = fence(String(line.text.dropFirst(line.indent))),
                closing.ch == opening.ch, closing.len >= opening.len, closing.info.isEmpty
            {
                j += 1
                break
            }
            body.append(line.dropping(ind).text)
            j += 1
        }
        let lang =
            opening.info.split(separator: " ").first.map { " class=\"language-\(MarkdownHTML.esc(String($0)))\"" } ?? ""
        let code = body.isEmpty ? "" : MarkdownHTML.esc(body.joined(separator: "\n")) + "\n"
        return ("<pre><code\(lang)>\(code)</code></pre>", j)
    }

    private func blockquote(_ ls: [Line], _ i: Int) -> (String?, Int) {
        var inner: [Line] = [], j = i
        while j < ls.count {
            let line = ls[j], quoted = line.text.dropFirst(min(line.indent, 3))
            if line.indent < 4, quoted.hasPrefix(">") {
                var rest = quoted.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                inner.append(Line(text: String(rest)))
            } else if !line.blank, inner.last?.blank == false, !interrupts(line.text) {
                inner.append(line)   // lazy continuation
            } else {
                break
            }
            j += 1
        }
        return (alert(inner) ?? "<blockquote>\n\(blocks(inner))\n</blockquote>", j)
    }

    /// A paragraph, or a setext heading when an `===` / `---` line ends it.
    private func paragraph(_ ls: [Line], _ i: Int, tight: Bool) -> (String?, Int) {
        var text: [String] = [], j = i, setext = 0
        while j < ls.count {
            let line = ls[j]
            if line.blank { break }
            if j > i {
                let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                if line.indent < 4, let mark = trimmed.first, mark == "=" || mark == "-",
                    trimmed.allSatisfy({ $0 == mark })
                {
                    setext = mark == "=" ? 1 : 2
                    j += 1
                    break
                }
                if interrupts(line.text) || isTable(ls, j) { break }
            }
            text.append(String(line.text.drop { $0 == " " }))
            j += 1
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
        let seen = slugs[base, default: 0]
        slugs[base] = seen + 1
        let id = seen == 0 ? base : "\(base)-\(seen)"
        return "<h\(level) id=\"\(MarkdownHTML.esc(id))\">\(html)</h\(level)>"
    }

    private func list(_ ls: [Line], _ i: Int, _ m0: Marker) -> (String, Int) {
        var items: [[Line]] = [], j = i, cur = m0, loose = false
        while true {
            var body = [Line(text: cur.rest)]
            j += 1
            while j < ls.count {
                let line = ls[j]
                if line.blank {
                    body.append(Line(text: ""))
                } else if line.indent >= cur.content {
                    body.append(line.dropping(cur.content))
                } else if marker(line.text) == nil, body.last?.blank == false, !interrupts(line.text) {
                    body.append(line)
                }   // lazy
                else {
                    break
                }
                j += 1
            }
            var trailing = 0
            while body.count > 1, body.last?.blank == true {
                body.removeLast()
                trailing += 1
            }
            // Limit: blank line followed by an unindented line inside an item counts as loose; fenced code with blank lines can false-positive.
            if zip(body, body.dropFirst()).contains(where: { $0.blank && !$1.blank && $1.indent == 0 }) { loose = true }
            items.append(body)
            guard j < ls.count, let nm = marker(ls[j].text), nm.kind == m0.kind,
                !isHR(String(ls[j].text.dropFirst(ls[j].indent)))
            else { break }
            if trailing > 0 { loose = true }
            cur = nm
        }
        let tag = m0.ordered ? "ol" : "ul"
        let start = m0.ordered && m0.start != 1 ? " start=\"\(m0.start)\"" : ""
        var html = "<\(tag)\(start)>\n"
        for var body in items {
            var box = ""
            let first = body[0].text
            if first.hasPrefix("[ ]") || first.hasPrefix("[x]") || first.hasPrefix("[X]"),
                first.count == 3 || first.dropFirst(3).first == " "
            {
                box = "<input type=\"checkbox\" disabled\(first.hasPrefix("[ ]") ? "" : " checked")> "
                body[0].text = String(first.dropFirst(4))
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

    private func cells(_ row: String) -> [String] {
        var trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var out: [String] = [], cur = "", prev: Character = " "
        for char in trimmed {
            if char == "|", prev != "\\" {
                out.append(cur)
                cur = ""
            } else if char == "|" {
                cur.removeLast()
                cur.append(char)
            } else {
                cur.append(char)
            }
            prev = char
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func aligns(_ row: String) -> [String]? {
        guard row.contains("|") else { return nil }
        var out: [String] = []
        for cell in cells(row) {
            var dashes = Substring(cell)
            if dashes.first == ":" { dashes = dashes.dropFirst() }
            if dashes.last == ":" { dashes = dashes.dropLast() }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(
                cell.hasPrefix(":") && cell.hasSuffix(":")
                    ? "center" : cell.hasSuffix(":") ? "right" : cell.hasPrefix(":") ? "left" : "")
        }
        return out
    }

    private func isTable(_ ls: [Line], _ i: Int) -> Bool {
        guard i + 1 < ls.count, ls[i].indent < 4, ls[i].text.contains("|"),
            let alignments = aligns(ls[i + 1].text)
        else {
            return false
        }
        return alignments.count == cells(ls[i].text).count
    }

    private func table(_ ls: [Line], _ i: Int) -> (String, Int) {
        let al = aligns(ls[i + 1].text) ?? []
        func row(_ line: Line, _ tag: String) -> String {
            let cs = cells(line.text)
            let tds = al.indices.map { column in
                let style = al[column].isEmpty ? "" : " style=\"text-align:\(al[column])\""
                return "<\(tag)\(style)>\(column < cs.count ? inline(cs[column]) : "")</\(tag)>"
            }
            return "<tr>\(tds.joined())</tr>"
        }
        var html = "<table>\n<thead>\n\(row(ls[i], "th"))\n</thead>\n"
        var next = i + 2, body: [String] = []
        while next < ls.count, !ls[next].blank, ls[next].text.contains("|"), !interrupts(ls[next].text) {
            body.append(row(ls[next], "td"))
            next += 1
        }
        if !body.isEmpty { html += "<tbody>\n\(body.joined(separator: "\n"))\n</tbody>\n" }
        return (html + "</table>", next)
    }

    private func fence(_ text: String) -> (ch: Character, len: Int, info: String)? {
        guard let mark = text.first, mark == "`" || mark == "~" else { return nil }
        let len = text.prefix { $0 == mark }.count
        let info = text.dropFirst(len).trimmingCharacters(in: .whitespaces)
        guard len >= 3, mark == "~" || !info.contains("`") else { return nil }
        return (mark, len, info)
    }

    private func atx(_ text: String) -> (Int, String)? {
        let level = text.prefix { $0 == "#" }.count
        let rest = text.dropFirst(level)
        guard (1...6).contains(level), rest.isEmpty || rest.first == " " else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        if let last = title.lastIndex(where: { $0 != "#" }) {
            if title[last] == " " { title = String(title[...last]).trimmingCharacters(in: .whitespaces) }
        } else {
            title = ""
        }
        return (level, title)
    }

    private func isHR(_ text: String) -> Bool {
        guard let mark = text.first, "-*_".contains(mark) else { return false }
        return text.allSatisfy { $0 == mark || $0 == " " || $0 == "\t" } && text.filter { $0 == mark }.count >= 3
    }

    private func marker(_ line: String) -> Marker? {
        let ind = line.prefix { $0 == " " }.count
        guard ind < 4 else { return nil }
        let chars = Array(line.dropFirst(ind))
        var end = 0, ordered = false, start = 0
        guard let c0 = chars.first else { return nil }
        var kind = c0
        if "-*+".contains(c0) {
            end = 1
        } else {
            while end < chars.count, end < 9, chars[end].isASCII, chars[end].isNumber { end += 1 }
            guard end > 0, end < chars.count, chars[end] == "." || chars[end] == ")",
                let number = Int(String(chars[0..<end]))
            else { return nil }
            kind = chars[end]
            start = number
            ordered = true
            end += 1
        }
        guard end == chars.count || chars[end] == " " else { return nil }
        let sp = chars[end...].prefix { $0 == " " }.count
        let rest = String(chars[(end + sp)...])
        if rest.isEmpty || sp > 4 {
            return Marker(
                indent: ind, kind: kind, ordered: ordered, start: start, content: ind + end + 1,
                rest: rest.isEmpty ? "" : String(chars[min(end + 1, chars.count)...]))
        }
        return Marker(indent: ind, kind: kind, ordered: ordered, start: start, content: ind + end + sp, rest: rest)
    }

    /// Lines that end a paragraph (and so can't be lazy continuations).
    private func interrupts(_ line: String) -> Bool {
        let ind = line.prefix { $0 == " " }.count
        guard ind < 4 else { return false }
        let text = String(line.dropFirst(ind))
        if fence(text) != nil || atx(text) != nil || isHR(text) || text.hasPrefix(">")
            || startsHTML(text, interrupting: true)
        {
            return true
        }
        if let listMarker = marker(line), !listMarker.rest.isEmpty, !listMarker.ordered || listMarker.start == 1 {
            return true
        }
        return false
    }

    private func def(_ text: String) -> (label: String, url: String, title: String?)? {
        guard text.hasPrefix("["), text.contains("]:"),
            let match = text.wholeMatch(of: /\[([^\]]+)\]:\s*<?([^\s>]+)>?(?:\s+["'(](.*)["')])?\s*/)
        else { return nil }
        return (norm(String(match.1)), String(match.2), match.3.map(String.init))
    }

    func norm(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: inline

}
