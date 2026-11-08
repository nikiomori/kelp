import Core
import Foundation
import Markdown

/// A review an agent wrote (`.kelp/artifacts/<name>/review.md`) as a page to answer: each point's options are a choice
/// you click, a note goes under a point, and the bar sends the picks to the chat that wrote it. The page only reports
/// clicks (`kelpSync`: pick / note / send); the tab writes them into the file, which then draws the page again.
enum ReviewPage {
    /// `sendTo`: the chat's name on the button; nil when it has ended (the picks go to the agent on screen).
    static func body(_ r: Review, sendTo: String?) -> String {
        var html = "<h1>\(MarkdownHTML.esc(r.title))</h1>\n"
        if !r.intro.isEmpty { html += "<div class=\"k-intro\">\(MarkdownHTML.render(r.intro))</div>\n" }
        for p in r.points {
            html +=
                "<section class=\"k-point\"><div class=\"k-q\"><span class=\"k-n\">\(MarkdownHTML.esc(p.number))</span><h2>\(inline(p.question))</h2></div>"
            html += "<div class=\"k-opts\">"
            for o in p.options {
                let rec =
                    o.recommended
                    ? "<span class=\"k-rec\">\(MarkdownHTML.esc(String(localized: "Recommended")))</span>" : ""
                let detail = o.detail.isEmpty ? "" : "<span class=\"k-d\">\(inline(o.detail))</span>"
                html +=
                    "<button type=\"button\" class=\"k-opt\(o.picked ? " on" : "")\" aria-pressed=\"\(o.picked)\" "
                    + "data-p=\"\(MarkdownHTML.esc(p.number))\" data-k=\"\(MarkdownHTML.esc(o.key))\">"
                    + "<span class=\"k-dot\"></span><span class=\"k-key\">\(MarkdownHTML.esc(o.key))</span>"
                    + "<span class=\"k-t\"><span class=\"k-line\">\(inline(o.text))\(rec)</span>\(detail)</span></button>"
            }
            html +=
                "</div><input class=\"k-note\" data-p=\"\(MarkdownHTML.esc(p.number))\" value=\"\(MarkdownHTML.esc(p.note))\" "
                + "placeholder=\"\(MarkdownHTML.esc(String(localized: "Add a note…")))\" "
                + "aria-label=\"\(MarkdownHTML.esc(String(localized: "Note on point \(p.number)")))\"></section>\n"
        }
        let picks = r.points.compactMap { p in p.pick.map { p.number + $0 } }.joined(separator: " ")
        let button = sendTo.map { String(localized: "Send to \($0)") } ?? String(localized: "Send to the Agent")
        html +=
            "<div class=\"k-bar\"><span class=\"k-sum\">\(MarkdownHTML.esc(picks.isEmpty ? String(localized: "Pick an option in each point") : picks))</span>"
            + "<button type=\"button\" class=\"k-send\"\(picks.isEmpty ? " disabled" : "")>"
            + "\(MarkdownHTML.esc(button))</button></div>"
        return html
    }

    /// The page's look on top of the Markdown one.
    static let style = """
        <style>
        :root{--k-acc:#007aff}:root.dark{--k-acc:#0a84ff}@supports (color:AccentColor){:root,:root.dark{--k-acc:AccentColor}}
        .markdown-body{padding-bottom:96px}
        .k-point{margin:0 0 22px}.k-q{display:flex;gap:10px;align-items:baseline}.k-q h2{margin:0 0 8px;border:0;font-size:1.1em}
        .k-n{font:600 13px ui-monospace,monospace;opacity:.55}
        .k-opts{display:flex;flex-direction:column;gap:6px;padding-left:22px}
        .k-opt{display:flex;gap:10px;align-items:flex-start;text-align:left;padding:9px 12px;border-radius:8px;font:inherit;color:inherit;
          background:none;border:1px solid color-mix(in srgb,currentColor 12%,transparent);cursor:pointer;transition:background .15s,border-color .15s}
        .k-opt:hover{background:color-mix(in srgb,currentColor 6%,transparent)}
        .k-opt.on{border-color:var(--k-acc);background:color-mix(in srgb,var(--k-acc) 14%,transparent)}
        .k-dot{width:14px;height:14px;flex:none;margin-top:3px;border-radius:7px;box-sizing:border-box;
          border:1.5px solid color-mix(in srgb,currentColor 30%,transparent)}
        .k-opt.on .k-dot{border:4px solid var(--k-acc)}
        .k-key{font:600 12px ui-monospace,monospace;opacity:.55;margin-top:2px}
        .k-t{display:flex;flex-direction:column;gap:3px}.k-line{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
        .k-d{font-size:.85em;opacity:.6}
        .k-rec{font-size:10px;font-weight:500;padding:1px 5px;border-radius:4px;background:color-mix(in srgb,currentColor 8%,transparent);opacity:.75}
        .k-note{display:block;margin:6px 0 0 22px;width:calc(100% - 22px);box-sizing:border-box;font:inherit;font-size:.85em;color:inherit;
          padding:5px 10px;border-radius:6px;border:0;background:color-mix(in srgb,currentColor 5%,transparent)}
        .k-note:focus{outline:2px solid var(--k-acc)}
        .k-bar{position:fixed;left:50%;bottom:16px;transform:translateX(-50%);display:flex;align-items:center;gap:12px;height:40px;box-sizing:border-box;
          padding:0 6px 0 14px;border-radius:20px;background:var(--bg);border:1px solid color-mix(in srgb,currentColor 12%,transparent);
          box-shadow:0 2px 6px rgba(0,0,0,.2);white-space:nowrap;font-size:13px}
        .k-sum{font-family:ui-monospace,monospace;font-size:12px}
        .k-send{height:28px;padding:0 12px;border:0;border-radius:14px;background:var(--k-acc);color:#fff;font:500 12px -apple-system,sans-serif;cursor:pointer}
        .k-send:disabled{opacity:.4;cursor:default}
        @media (prefers-reduced-motion:reduce){.k-opt{transition:none}}
        </style>
        """

    /// Its clicks: JavaScript, run beside the page (`MarkdownTab.world`).
    static let script = """
        const post = m => webkit.messageHandlers.kelpSync?.postMessage(m);
        document.querySelectorAll('.k-opt').forEach(b => b.addEventListener('click', () => post({ kind: 'pick', point: b.dataset.p, key: b.dataset.k })));
        document.querySelectorAll('.k-note').forEach(i => {
          const save = () => post({ kind: 'note', point: i.dataset.p, text: i.value });
          i.addEventListener('change', save);
          i.addEventListener('keydown', e => { if (e.key === 'Enter') i.blur(); });
        });
        document.querySelector('.k-send')?.addEventListener('click', () => post({ kind: 'send' }));
        function kelpReviewSent(text) { const s = document.querySelector('.k-sum'); if (s) s.textContent = text; }
        """

    /// A line of Markdown inline (code, emphasis, links), without the paragraph around it.
    private static func inline(_ s: String) -> String {
        let html = MarkdownHTML.render(s).trimmingCharacters(in: .whitespacesAndNewlines)
        guard html.hasPrefix("<p>"), html.hasSuffix("</p>") else { return html }
        return String(html.dropFirst(3).dropLast(4))
    }
}
