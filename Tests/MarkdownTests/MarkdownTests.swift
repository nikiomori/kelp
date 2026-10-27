import Foundation
import Testing
@testable import Markdown

private func r(_ md: String) -> String { MarkdownHTML.render(md) }

// MARK: blocks

@Test func headingsWithSlugs() {
    let h = r("# Hello, World!\n## Hello, World!\n### `code` *x* ###\n#nope")
    #expect(h.contains(#"<h1 id="hello-world">Hello, World!</h1>"#))
    #expect(h.contains(#"<h2 id="hello-world-1">"#))
    #expect(h.contains(#"<h3 id="code-x"><code>code</code> <em>x</em></h3>"#))
    #expect(h.contains(#"<p>#nope</p>"#))
    #expect(r("Title\n=====\n\nSub\n---").contains(#"<h2 id="sub">Sub</h2>"#))
}

@Test func paragraphsAndBreaks() {
    let h = r("one\ntwo  \nthree\\\nfour\n\nnext")
    #expect(h.contains("<p>one\ntwo<br>\nthree<br>\nfour</p>"))
    #expect(h.contains(#"<p>next</p>"#))
}

@Test func emphasis() {
    #expect(r("*a* _b_ **c** __d__ ~~e~~ ***f***") ==
            #"<p><em>a</em> <em>b</em> <strong>c</strong> <strong>d</strong> <del>e</del> <em><strong>f</strong></em></p>"#)
    #expect(r("snake_case_name and 2*3*4") == #"<p>snake_case_name and 2<em>3</em>4</p>"#)
    #expect(r("**bold *nested* bold**") == #"<p><strong>bold <em>nested</em> bold</strong></p>"#)
    #expect(r("a * b * c") == #"<p>a * b * c</p>"#)
    #expect(r(#"\*not\*"#) == #"<p>*not*</p>"#)
}

@Test func inlineCode() {
    #expect(r("use `a <b> & *c*` and `` x`y ``") == #"<p>use <code>a &lt;b&gt; &amp; *c*</code> and <code>x`y</code></p>"#)
}

@Test func fencedAndIndentedCode() {
    let h = r("```swift\nlet x = 1 < 2\n\n```\n\n~~~\nplain\n~~~\n\n    indented\n    <tag>")
    #expect(h.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2\n\n</code></pre>"))
    #expect(h.contains("<pre><code>plain\n</code></pre>"))
    #expect(h.contains("<pre><code>indented\n&lt;tag&gt;\n</code></pre>"))
    #expect(r("```\nunclosed *x*").contains("<code>unclosed *x*\n</code>"))
}

@Test func blockquotesNest() {
    let h = r("> outer\nlazy\n> > inner\n> back")
    #expect(h.hasPrefix("<blockquote>\n<p>outer\nlazy</p>\n<blockquote>"))
    #expect(h.contains("<p>inner\nback</p>"))
}

@Test func listsNestByIndent() {
    let h = r("- a\n  - b\n    - c\n- d\n\n3. x\n4. y")
    #expect(h.contains("<ul>\n<li>a\n<ul>\n<li>b\n<ul>\n<li>c</li>"))
    #expect(h.contains("<li>d</li>\n</ul>"))
    #expect(h.contains("<ol start=\"3\">\n<li>x</li>\n<li>y</li>\n</ol>"))
    #expect(r("1. one\n   - sub\n2. two").contains("<li>one\n<ul>"))
}

@Test func looseListsWrapParagraphs() {
    let h = r("- a\n\n- b\n\n  more")
    #expect(h.contains(#"<li><p>a</p></li>"#))
    #expect(h.contains("<p>more</p>"))
}

@Test func taskLists() {
    let h = r("- [ ] todo\n- [x] done\n- plain")
    #expect(h.contains(#"<li class="task-list-item"><input type="checkbox" disabled> todo</li>"#))
    #expect(h.contains(#"<li class="task-list-item"><input type="checkbox" disabled checked> done</li>"#))
    #expect(h.contains(#"<li>plain</li>"#))
}

@Test func tablesWithAlignment() {
    let h = r("| L | C | R | N |\n|:--|:-:|--:|---|\n| a | `b\\|c` | **r** |\n\nafter")
    #expect(h.contains("<table>\n<thead>\n<tr><th style=\"text-align:left\">L</th>"
        + "<th style=\"text-align:center\">C</th><th style=\"text-align:right\">R</th><th>N</th></tr>"))
    #expect(h.contains(#"<tr><td style="text-align:left">a</td><td style="text-align:center"><code>b|c</code></td><td style="text-align:right"><strong>r</strong></td><td></td></tr>"#))
    #expect(h.contains(#"<p>after</p>"#))
    #expect(!r("a | b\n---").contains("<table"))
}

@Test func linksImagesAutolinks() {
    #expect(r("[x *y*](https://a.b/c?d=1&e=2 \"T\")") == #"<p><a href="https://a.b/c?d=1&amp;e=2" title="T">x <em>y</em></a></p>"#)
    #expect(r("![alt *t*](img/a.png)") == #"<p><img src="img/a.png" alt="alt t"></p>"#)
    #expect(r("<https://x.io> and <me@x.io>") == #"<p><a href="https://x.io">https://x.io</a> and <a href="mailto:me@x.io">me@x.io</a></p>"#)
    #expect(r("see https://x.io/a_(b). or www.y.com,")
        == #"<p>see <a href="https://x.io/a_(b)">https://x.io/a_(b)</a>. or <a href="http://www.y.com">www.y.com</a>,</p>"#)
    #expect(r("[ref] and [t][Ref]\n\n[ref]: /r \"tt\"") == #"<p><a href="/r" title="tt">ref</a> and <a href="/r" title="tt">t</a></p>"#)
    #expect(r("[x](javascript:alert(1))").contains(##"href="#""##))
}

@Test func horizontalRules() {
    #expect(r("a\n\n***\n- - -\n___") == "<p>a</p>\n<hr>\n<hr>\n<hr>")
}

@Test func escapesHTMLButTheSafeTags() {
    let h = r("<script>alert('x')</script>\n\n# <b>h</b>\n\n> <img src=x onerror=y>\n\n| <i> |\n|---|\n| & |")
    #expect(!h.contains("<script"))
    #expect(h.contains("&lt;script&gt;alert('x')&lt;/script&gt;"))
    #expect(h.contains("<b>h</b>"))
    #expect(h.contains(#"<img src="x">"#) && !h.contains("onerror"))
    #expect(h.contains("<th><i></th>") && h.contains("<td>&amp;</td>"))
    #expect(r(#"<a href="javascript:alert(1)" onclick="x" style="color:red">a</a>"#) == ##"<p><a href="#">a</a></p>"##)
    #expect(r(#"<p align="center"><img src="logo.png" width="120" onload="x"></p>"#) == #"<p align="center"><img src="logo.png" width="120"></p>"#)
    #expect(r("<iframe src=x></iframe>").contains("&lt;iframe"))
    #expect(r("a <!-- hidden --> b") == #"<p>a  b</p>"#)
    #expect(r("&copy; & co") == #"<p>&copy; &amp; co</p>"#)
}

@Test func pageDocument() {
    let p = MarkdownHTML.page(body: "<p>x</p>", baseURL: URL(fileURLWithPath: "/r/README.md"), dark: true)
    #expect(p.hasPrefix("<!doctype html>"))
    #expect(p.contains(#"<html class="dark">"#) && p.contains(#"<base href="file:///r/README.md">"#))
    #expect(p.contains("prefers-color-scheme") && p.contains("-apple-system") && p.contains("max-width:860px"))
    #expect(!p.contains("http"))
    #expect(!MarkdownHTML.page(body: "", baseURL: nil, dark: false).contains("class=\"dark\""))
}

// MARK: templates

@Test func templateExpansion() throws {
    let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 9, minute: 7)))
    let out = Templates.expand("{{date}} {{time}} {{ datetime }} {{branch}}/{{repo}}: {{title}} {{who}} {{unknown}}",
                               vars: ["branch": "feat", "repo": "kelp", "title": "Plan", "who": "me"], now: now)
    #expect(out == "2026-03-05 09:07 2026-03-05 09:07 feat/kelp: Plan me {{unknown}}")
}

@Test func templateListing() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for n in ["b.md", "a.md", "c.txt", "A10.md", "A2.md"] { try Data().write(to: dir.appendingPathComponent(n)) }
    #expect(Templates.list(in: dir).map(\.lastPathComponent) == ["a.md", "A2.md", "A10.md", "b.md"])
    #expect(Templates.list(in: dir.appendingPathComponent("missing")).isEmpty)
}

// MARK: formatting

private func sel(_ t: String, _ s: String) -> NSRange { (t as NSString).range(of: s) }

@Test func boldItalicToggle() {
    let t = "say hi now"
    let on = MarkdownFormat.toggleBold(t, sel(t, "hi"))
    #expect(on.text == "say **hi** now" && on.selection == NSRange(location: 6, length: 2))
    let off = MarkdownFormat.toggleBold(on.text, on.selection)
    #expect(off.text == t && off.selection == NSRange(location: 4, length: 2))
    #expect(MarkdownFormat.toggleBold("**hi**", NSRange(location: 0, length: 6)).text == "hi")
    let caret = MarkdownFormat.toggleBold("ab", NSRange(location: 1, length: 0))
    #expect(caret.text == "a****b" && caret.selection == NSRange(location: 3, length: 0))
    #expect(MarkdownFormat.toggleBold(caret.text, caret.selection).text == "ab")
    let it = MarkdownFormat.toggleItalic(t, sel(t, "hi"))
    #expect(it.text == "say _hi_ now")
    #expect(MarkdownFormat.toggleItalic(it.text, it.selection).text == t)
}

@Test func codeToggle() {
    let on = MarkdownFormat.toggleCode("run x", NSRange(location: 4, length: 1))
    #expect(on.text == "run `x`")
    #expect(MarkdownFormat.toggleCode(on.text, on.selection).text == "run x")
    let block = MarkdownFormat.toggleCode("a\nb", NSRange(location: 0, length: 3))
    #expect(block.text == "```\na\nb\n```" && block.selection == NSRange(location: 4, length: 3))
    #expect(MarkdownFormat.toggleCode(block.text, block.selection).text == "a\nb")
}

@Test func linkToggle() {
    let on = MarkdownFormat.makeLink("go home", NSRange(location: 3, length: 4))
    #expect(on.text == "go [home](url)" && (on.text as NSString).substring(with: on.selection) == "url")
    let off = MarkdownFormat.makeLink(on.text, NSRange(location: 3, length: 11))
    #expect(off.text == "go home" && off.selection == NSRange(location: 3, length: 4))
    let u = MarkdownFormat.makeLink("https://x.io", NSRange(location: 0, length: 12))
    #expect(u.text == "[](https://x.io)" && u.selection == NSRange(location: 1, length: 0))
}

@Test func headingToggle() {
    let on = MarkdownFormat.heading("title", NSRange(location: 2, length: 0), level: 2)
    #expect(on.text == "## title" && on.selection == NSRange(location: 5, length: 0))
    #expect(MarkdownFormat.heading(on.text, on.selection, level: 1).text == "# title")
    #expect(MarkdownFormat.heading(on.text, on.selection, level: 2).text == "title")
    let multi = MarkdownFormat.heading("a\n\nb\nc", NSRange(location: 0, length: 4), level: 3)
    #expect(multi.text == "### a\n\n### b\nc" && multi.selection == NSRange(location: 0, length: 12))
}

@Test func listToggles() {
    let t = "a\nb\n\nc"
    let all = NSRange(location: 0, length: (t as NSString).length)
    let b = MarkdownFormat.toggleBullet(t, all)
    #expect(b.text == "- a\n- b\n\n- c" && b.selection == NSRange(location: 0, length: 12))
    #expect(MarkdownFormat.toggleBullet(b.text, b.selection).text == t)
    let n = MarkdownFormat.toggleNumbered(b.text, b.selection)
    #expect(n.text == "1. a\n2. b\n\n3. c")
    #expect(MarkdownFormat.toggleNumbered(n.text, n.selection).text == t)
    let k = MarkdownFormat.toggleTask("  - x\n- [x] y", NSRange(location: 0, length: 13))
    #expect(k.text == "  - [ ] x\n- [x] y")
    #expect(MarkdownFormat.toggleTask(k.text, k.selection).text == "  x\ny")
    let caret = MarkdownFormat.toggleBullet("one\ntwo", NSRange(location: 5, length: 0))
    #expect(caret.text == "one\n- two" && caret.selection == NSRange(location: 7, length: 0))
    let nl = MarkdownFormat.toggleBullet("a\nb\nc", NSRange(location: 0, length: 4)) // selection ends after "b\n"
    #expect(nl.text == "- a\n- b\nc")
}

@Test func tableInsert() {
    let e = MarkdownFormat.insertTable("text", NSRange(location: 4, length: 0))
    #expect(e.text == "text\n| Column | Column |\n| ------ | ------ |\n|        |        |\n|        |        |\n")
    #expect((e.text as NSString).substring(with: e.selection) == "Column")
    #expect(MarkdownHTML.render(e.text).contains("<table>"))
}

@Test func notebookRender() throws {
    let nb = """
    {"cells":[{"cell_type":"markdown","source":["# Title\\n","Some *text*"]},
     {"cell_type":"code","execution_count":3,"source":"print('<hi>')","outputs":[
       {"output_type":"stream","name":"stdout","text":["<hi>\\n"]},
       {"output_type":"display_data","data":{"image/png":"iVBORw0KGgo=","text/plain":"<Figure>"}},
       {"output_type":"error","ename":"ValueError","evalue":"bad","traceback":["\\u001b[31mValueError\\u001b[0m: bad"]}]}],
     "metadata":{"language_info":{"name":"python"}},"nbformat":4}
    """
    let html = try #require(NotebookHTML.render(Data(nb.utf8)))
    #expect(html.contains("<h1"))
    #expect(html.contains("In [3]:"))
    #expect(html.contains("print(&#39;&lt;hi&gt;&#39;)") || html.contains("print('&lt;hi&gt;')"))
    #expect(html.contains("data:image/png;base64,iVBORw0KGgo="))
    #expect(html.contains("ValueError: bad") && !html.contains("\u{1B}"))
    #expect(!html.contains("<hi>"))
    #expect(NotebookHTML.summary(Data(nb.utf8)) == .init(cells: 2, language: "python"))
}

/// What a cloned repo's notebook holds can't leave its text or attribute: no markup, no handlers.
@Test func hostileNotebookStaysInert() throws {
    let nb = #"{"metadata":{"language_info":{"name":"x\"><img src=x onerror=alert(1)>"}},"#
        + #""cells":[{"cell_type":"code","source":"1","outputs":[{"output_type":"display_data","data":{"image/png":"\" onerror=\"alert(2)"}}]}]}"#
    let html = try #require(NotebookHTML.render(Data(nb.utf8)))
    #expect(!html.contains("onerror=") && !html.contains("<img src=x"))
    #expect(html.contains("class=\"language-ximgsrcxonerroralert1\""))
}

@Test func mermaidOnlyWhenThereIsADiagram() {
    #expect(MarkdownHTML.mermaid(for: "# Plain\n\n```swift\nlet x = 1\n```", dark: false) == nil)
    let page = MarkdownHTML.mermaid(for: "```mermaid\ngraph LR\n  A --> B\n```", dark: true)
    #expect(page?.contains("mermaid.initialize") == true && page?.contains("theme: 'dark'") == true)
    #expect((MarkdownHTML.mermaidJS?.count ?? 0) > 1_000_000)   // bundled, not fetched
    #expect(MarkdownHTML.render("```mermaid\ngraph LR\n```").contains("language-mermaid"))
}

// MARK: GitHub's additions

@Test func alerts() {
    let h = r("> [!WARNING]\n> Mind the **gap**.\n\n> [!note]\n> Lower case too.\n\n> [!FOO]\n> Just a quote.")
    #expect(h.contains(#"<div class="markdown-alert markdown-alert-warning">"#))
    #expect(h.contains(#"<p class="markdown-alert-title">Warning</p>"#) && h.contains("<p>Mind the <strong>gap</strong>.</p>"))
    #expect(h.contains("markdown-alert-note"))
    #expect(h.contains("<blockquote>\n<p>[!FOO]\nJust a quote.</p>"))
}

@Test func detailsAndInlineTags() {
    let h = r("<details>\n<summary>More</summary>\n\nHidden *text*.\n\n</details>\n\nPress <kbd>⌘</kbd>+<kbd>K</kbd>, x<sup>2</sup>.")
    #expect(h.contains("<details>\n<summary>More</summary>"))
    #expect(h.contains("<p>Hidden <em>text</em>.</p>") && h.contains("</details>"))
    #expect(h.contains("Press <kbd>⌘</kbd>+<kbd>K</kbd>, x<sup>2</sup>."))
    let pic = r(#"<picture><source media="(prefers-color-scheme: dark)" srcset="dark.png"><img src="light.png" alt="logo"></picture>"#)
    #expect(pic == #"<picture><source media="(prefers-color-scheme: dark)" srcset="dark.png"><img src="light.png" alt="logo"></picture>"#)
    #expect(r("a\n<div>b</div>").contains("<p>a</p>\n<div>b</div>"))   // a block tag ends a paragraph
}

@Test func footnotes() {
    let h = r("Claim[^src] and another[^2].\n\n[^2]: Second.\n[^src]: The source,\n    with more.\n\nAfter.")
    #expect(h.contains(##"Claim<sup class="footnote-ref"><a href="#fn-1" id="fnref-1">1</a></sup>"##))
    #expect(h.contains(##"another<sup class="footnote-ref"><a href="#fn-2" id="fnref-2">2</a></sup>"##))
    #expect(h.contains(#"<section class="footnotes">"#))
    #expect(h.contains(#"<li id="fn-1">The source,"#) && h.contains(##"with more. <a href="#fnref-1" class="footnote-backref">↩</a></li>"##))
    #expect(h.contains(##"<li id="fn-2">Second. <a href="#fnref-2" class="footnote-backref">↩</a></li>"##))
    #expect(h.contains("<p>After.</p>") && !h.contains("[^2]:"))
    #expect(r("No note[^x].") == "<p>No note[^x].</p>")
}
