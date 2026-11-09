import Foundation
import SwiftMarkdown

/// GitHub-flavoured Markdown → HTML: cmark-gfm parses (swift-markdown), `HTMLWriter` writes.
/// Raw HTML is escaped, but for the tags and attributes on a list (MarkdownGFM): safety over fidelity.
public enum MarkdownHTML {
    /// `marking`: each top-level block goes after an invisible mark of its source line, for `scrollSync` to go by.
    public static func render(_ md: String, marking: Bool = false) -> String {
        var writer = HTMLWriter(), math = MarkdownMath()
        let source = writer.takeNotes(math.takeOut(md.replacingOccurrences(of: "\r\n", with: "\n")))
        return math.putBack(
            writer.blocks(Document(parsing: source, options: .disableSmartOpts), marking: marking) + writer.footnotes())
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

    static let mermaidJS = resource("mermaid.min", "js")

    /// Formulas (`MarkdownMath`'s spans in a rendered `body`) drawn with the bundled KaTeX, its fonts inside its CSS
    /// (no network); nil when there are none. JavaScript, as `scrollSync`. A formula KaTeX can't read shows its error in
    /// red.
    public static func math(for body: String) -> String? {
        guard body.contains("kelp-math"), let js = katexJS, let css = katexCSS else { return nil }
        return js + """

            (() => {
              const s = document.createElement('style'); s.textContent = atob('\(css)'); document.head.append(s);
              document.querySelectorAll('.kelp-math').forEach(e => katex.render(e.textContent, e,
                { displayMode: e.classList.contains('kelp-math-display'), throwOnError: false }));
            })();
            """
    }

    static let katexJS = resource("katex.min", "js")
    /// In base64 (all ASCII, so `atob` gives it back as it was).
    static let katexCSS = resource("katex.min", "css").map { Data($0.utf8).base64EncodedString() }
    private static func resource(_ name: String, _ ext: String) -> String? {
        Bundle.module.url(forResource: name, withExtension: ext).flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }
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
        .kelp-math-display{display:block;margin:0 0 16px;overflow-x:auto;overflow-y:hidden}
        """

    /// Safe in text and in double-quoted attributes (the only kind Kelp's pages write).
    public static func esc(_ text: String) -> String {
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

/// swift-markdown's tree as HTML, as GitHub writes it. What GitHub adds (alerts, footnotes, bare links, safe HTML) is in
/// MarkdownGFM.
struct HTMLWriter: MarkupVisitor {
    var slugs: [String: Int] = [:]
    /// Footnotes by label, and the order they're first referred to in (their numbers).
    var notes: [String: String] = [:]
    var noteOrder: [String] = []
    /// The list being written is tight: its items' paragraphs go without `<p>`, as do a footnote's.
    var tight = false, inNote = false
    /// In a link's text: no link in a link, no footnote reference.
    var inLink = false

    mutating func blocks(_ doc: Markup, marking: Bool = false) -> String {
        doc.children.compactMap { block -> String? in
            let html = visit(block)
            guard !html.isEmpty else { return nil }
            guard marking, let line = block.range?.lowerBound.line else { return html }
            return "<i data-line=\"\(line)\" style=\"display:block;height:0\"></i>\n" + html
        }.joined(separator: "\n")
    }

    mutating func children(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    mutating func defaultVisit(_ markup: Markup) -> String { inlines(markup.children) }

    // MARK: blocks

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let body = inlines(paragraph.children)
        let bare = paragraph.parent is ListItem ? tight : inNote && paragraph.parent is Document
        // `<picture>` starts no HTML block in CommonMark; Kelp's pages have always drawn it as one.
        let picture = (paragraph.child(at: 0) as? InlineHTML)?.rawHTML.lowercased().hasPrefix("<picture") == true
        return body.isEmpty || bare || picture ? body : "<p>\(body)</p>"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let html = inlines(heading.children)
        var base = ""
        for c in stripTags(html).replacing(/&#?\w+;/, with: "").lowercased() {
            if c.isLetter || c.isNumber || c == "-" || c == "_" { base.append(c) } else if c == " " { base.append("-") }
        }
        let seen = slugs[base, default: 0]
        slugs[base] = seen + 1
        let id = seen == 0 ? base : "\(base)-\(seen)"
        return "<h\(heading.level) id=\"\(MarkdownHTML.esc(id))\">\(html)</h\(heading.level)>"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String { "<hr>" }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        if codeBlock.language == "math" {
            return MarkdownMath.span(codeBlock.code.trimmingCharacters(in: .newlines), display: true)
        }
        let lang = codeBlock.language?.split(separator: " ").first.map {
            " class=\"language-\(MarkdownHTML.esc(String($0)))\""
        }
        return "<pre><code\(lang ?? "")>\(MarkdownHTML.esc(codeBlock.code))</code></pre>"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        alert(blockQuote) ?? "<blockquote>\n\(children(blockQuote))\n</blockquote>"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String { "<ul>\n\(items(list))</ul>" }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        return "<ol\(start)>\n\(items(list))</ol>"
    }

    private mutating func items(_ list: Markup) -> String {
        let outer = tight
        tight = !loose(list)
        defer { tight = outer }
        return list.children.map { visit($0) + "\n" }.joined()
    }

    /// CommonMark's loose list: a blank line between its items, or between two blocks in one of them.
    private func loose(_ list: Markup) -> Bool {
        func lastLine(_ markup: Markup) -> Int {
            markup.childCount > 0
                ? lastLine(markup.child(at: markup.childCount - 1) ?? markup) : markup.range?.upperBound.line ?? 0
        }
        let blocks = list.children.flatMap { Array($0.children) }
        return zip(blocks, blocks.dropFirst()).contains { ($1.range?.lowerBound.line ?? 0) > lastLine($0) + 1 }
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        var inner = children(listItem)
        guard let checkbox = listItem.checkbox else { return "<li>\(inner)</li>" }
        let box = "<input type=\"checkbox\" disabled\(checkbox == .checked ? " checked" : "")> "
        if inner.hasPrefix("<p>") {
            inner.insert(contentsOf: box, at: inner.index(inner.startIndex, offsetBy: 3))
        } else {
            inner = box + inner
        }
        return "<li class=\"task-list-item\">\(inner)</li>"
    }

    mutating func visitTable(_ table: Table) -> String {
        let aligns = table.columnAlignments.map { align -> String in
            switch align {
            case .left: " style=\"text-align:left\""
            case .center: " style=\"text-align:center\""
            case .right: " style=\"text-align:right\""
            case nil: ""
            }
        }
        var html = "<table>\n<thead>\n\(row(table.head, "th", aligns))\n</thead>\n"
        let body = table.body.children.map { row($0, "td", aligns) }
        if !body.isEmpty { html += "<tbody>\n\(body.joined(separator: "\n"))\n</tbody>\n" }
        return html + "</table>"
    }

    /// A row with a cell for each column: one it lacks is empty.
    private mutating func row(_ row: Markup, _ tag: String, _ aligns: [String]) -> String {
        let cells = Array(row.children)
        let html = aligns.indices.map { column in
            "<\(tag)\(aligns[column])>\(column < cells.count ? inlines(cells[column].children) : "")</\(tag)>"
        }
        return "<tr>\(html.joined())</tr>"
    }

    // MARK: inline

    /// Inline nodes, a run of text as one string (cmark splits it at `[`, `*`…) for footnote references and bare links.
    mutating func inlines(_ nodes: some Sequence<Markup>) -> String {
        var html = "", run = ""
        for node in nodes {
            if let text = node as? Text {
                run += text.string
                continue
            }
            html += text(run) + visit(node)
            run = ""
        }
        return html + text(run)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String { "<em>\(inlines(emphasis.children))</em>" }
    mutating func visitStrong(_ strong: Strong) -> String { "<strong>\(inlines(strong.children))</strong>" }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(inlines(strikethrough.children))</del>"
    }
    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(MarkdownHTML.esc(inlineCode.code))</code>"
    }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br>\n" }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { "\n" }

    mutating func visitLink(_ link: Link) -> String {
        let title = link.title.map { " title=\"\(MarkdownHTML.esc($0))\"" } ?? ""
        inLink = true
        defer { inLink = false }
        return "<a href=\"\(MarkdownHTML.esc(safe(link.destination ?? "")))\"\(title)>\(inlines(link.children))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let title = image.title.map { " title=\"\(MarkdownHTML.esc($0))\"" } ?? ""
        let src = MarkdownHTML.esc(safe(image.source ?? "", image: true))
        return "<img src=\"\(src)\" alt=\"\(MarkdownHTML.esc(image.plainText))\"\(title)>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String { sanitize(inlineHTML.rawHTML) }

    /// An HTML block that doesn't start with a tag on the list is the text it shows, in a paragraph.
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        let out = sanitize(html.rawHTML.trimmingCharacters(in: .newlines))
        return out.hasPrefix("&lt;") ? "<p>\(out)</p>" : out
    }
}
