import Core
import Foundation
import Markdown

/// Draws a review an agent wrote (`.kelp/artifacts/<name>/review.md`) as a page to answer. The user clicks one of a
/// point's options (or types 1–9 for the point, A–D for the option), and can add a note under a picked point. A
/// capsule at the foot shows which points have an answer, picks the recommended option wherever the user hasn't
/// picked, and sends the picks to the chat that wrote the review (⌘↩). Once sent, the picks stay and the other options
/// fade, until Change Answers. A point the agent has done says so. The page only reports clicks to `kelpSync` (pick /
/// note / send / recommended / unsend). The tab writes them into the file, and the changed file draws the page again.
enum ReviewPage {
    /// `sendTo` is the agent's name on the Send button. It is nil when the agent's chat has ended, and then the picks
    /// go to the agent on screen.
    static func body(_ review: Review, sendTo: String?) -> String {
        let esc = MarkdownHTML.esc
        var html = "<h1>\(esc(review.title))</h1>\n"
        if !review.intro.isEmpty { html += "<div class=\"k-intro\">\(MarkdownHTML.render(review.intro))</div>\n" }
        let sent = review.sent != nil
        for point in review.points {
            let done = point.done ? "<span class=\"k-done\">\(check)\(esc(String(localized: "Done")))</span>" : ""
            html +=
                "<section class=\"k-point\" id=\"p\(esc(point.number))\"><div class=\"k-q\">"
                + "<span class=\"k-n\">\(esc(point.number))</span><h2>\(inline(point.question))</h2>\(done)</div>"
            html += "<div class=\"k-opts\">"
            for option in point.options {
                let rec =
                    option.recommended ? "<span class=\"k-rec\">\(esc(String(localized: "Recommended")))</span>" : ""
                let detail = option.detail.isEmpty ? "" : "<span class=\"k-d\">\(inline(option.detail))</span>"
                let look = option.picked ? " on" : sent && point.pick != nil ? " dim" : ""
                html +=
                    "<button type=\"button\" class=\"k-opt\(look)\" aria-pressed=\"\(option.picked)\" "
                    + "data-p=\"\(esc(point.number))\" data-k=\"\(esc(option.key))\"\(sent ? " disabled" : "")>"
                    + "<span class=\"k-dot\"></span><span class=\"k-key\">\(esc(option.key))</span>"
                    + "<span class=\"k-t\"><span class=\"k-line\">\(inline(option.text))\(rec)</span>\(detail)</span></button>"
            }
            html += "</div>"
            let field =
                "<input class=\"k-note\" data-p=\"\(esc(point.number))\" value=\"\(esc(point.note))\" "
                + "placeholder=\"\(esc(String(localized: "Add a note…")))\" "
                + "aria-label=\"\(esc(String(localized: "Note on point \(point.number)")))\"\(sent ? " disabled" : "")>"
            if !point.note.isEmpty {
                html += field
            } else if point.pick != nil, !sent {
                html +=
                    "<button type=\"button\" class=\"k-pill k-addnote\">\(esc(String(localized: "Add Note")))</button>"
                    + field.replacingOccurrences(of: "class=\"k-note\"", with: "class=\"k-note\" hidden")
            }
            html += "</section>\n"
        }
        return html + capsule(review, sendTo: sendTo)
    }

    /// The capsule at the foot: how many points are answered, and what to do with the answers.
    private static func capsule(_ review: Review, sendTo: String?) -> String {
        let esc = MarkdownHTML.esc
        let picks = review.points.compactMap { p in p.pick.map { p.number + $0 } }.joined(separator: " ")
        let who = sendTo ?? String(localized: "the Agent")
        if let time = review.sent {
            return
                "<div class=\"k-bar\"><span class=\"k-ok\">\(check)\(esc(String(localized: "Sent to \(who)")))</span>"
                + "<span class=\"k-sum\">\(esc(time)) · \(esc(picks))</span><button type=\"button\" "
                + "class=\"k-pill k-unsend\">\(esc(String(localized: "Change Answers")))</button></div>"
        }
        let answered = review.points.filter { $0.pick != nil }.count
        let dots = review.points.map { point in
            "<button type=\"button\" class=\"k-pd\(point.pick != nil ? " on" : "")\" data-go=\"\(esc(point.number))\" "
                + "title=\"\(esc(point.number + ". " + point.question))\"></button>"
        }.joined()
        let rest = review.points.contains { $0.pick == nil && $0.options.contains(where: \.recommended) }
        let sum =
            picks.isEmpty
            ? String(localized: "Pick an option in each point")
            : picks + " · " + String(localized: "\(answered) of \(review.points.count)")
        let restButton =
            rest
            ? "<span class=\"k-sep\"></span><button type=\"button\" class=\"k-pill k-rest\">"
                + "\(esc(String(localized: "Recommended for the Rest")))</button>" : ""
        return
            "<div class=\"k-bar\"><span class=\"k-dots\">\(dots)</span><span class=\"k-sum\">\(esc(sum))</span>"
            + restButton
            + "<button type=\"button\" class=\"k-send\" title=\"⌘↩\"\(picks.isEmpty ? " disabled" : "")>"
            + "\(esc(String(localized: "Send to \(who)")))</button></div>"
            + "<div class=\"k-keys\">\(esc(String(localized: "1–9 point · A–D option · ⌘↩ send")))</div>"
    }

    /// The check before "Done" and "Sent to": drawn, in the text's own secondary colour (no green "done").
    private static let check =
        "<svg class=\"k-check\" aria-hidden=\"true\" viewBox=\"0 0 10 10\" fill=\"none\" stroke=\"currentColor\" "
        + "stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\">"
        + "<path d=\"M1.5 5.2 4 7.6 8.5 2.6\"/></svg>"

    /// The review page's CSS, applied on top of the Markdown page's CSS.
    static let style = """
        <style>
        :root{--k-acc:#007aff}:root.dark{--k-acc:#0a84ff}@supports (color:AccentColor){:root,:root.dark{--k-acc:AccentColor}}
        .markdown-body{padding-bottom:96px}
        .k-point{margin:0 0 22px;scroll-margin-top:24px}.k-q{display:flex;gap:10px;align-items:baseline}
        .k-q h2{margin:0 0 8px;border:0;font-size:1.1em;flex:1}
        .k-point.k-at .k-n{color:var(--k-acc);opacity:1}
        .k-n{font:600 13px ui-monospace,monospace;opacity:.55}
        .k-done{font-size:12px;font-weight:500;color:var(--muted);white-space:nowrap}
        .k-check{width:10px;height:10px;margin-right:4px;vertical-align:-1px}
        .k-opts{display:flex;flex-direction:column;gap:6px;padding-left:22px}
        .k-opt{display:flex;gap:10px;align-items:flex-start;text-align:left;padding:9px 12px;border-radius:8px;font:inherit;color:inherit;
          background:none;border:1px solid color-mix(in srgb,currentColor 12%,transparent);cursor:pointer;
          transition:background .15s,border-color .15s,opacity .15s}
        .k-opt:hover:not(:disabled){background:color-mix(in srgb,currentColor 6%,transparent)}
        .k-opt:disabled{cursor:default}
        .k-opt.on{border-color:var(--k-acc);background:color-mix(in srgb,var(--k-acc) 14%,transparent)}
        .k-opt.dim{opacity:.4}
        .k-dot{width:14px;height:14px;flex:none;margin-top:3px;border-radius:7px;box-sizing:border-box;
          border:1.5px solid color-mix(in srgb,currentColor 30%,transparent)}
        .k-opt.on .k-dot{border:4px solid var(--k-acc)}
        .k-key{font:600 12px ui-monospace,monospace;opacity:.55;margin-top:2px}
        .k-t{display:flex;flex-direction:column;gap:3px}.k-line{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
        .k-d{font-size:.85em;opacity:.6}
        .k-rec{font-size:10px;font-weight:500;padding:1px 5px;border-radius:4px;background:color-mix(in srgb,currentColor 8%,transparent);opacity:.75}
        .k-addnote{display:block;margin:6px 0 0 22px}
        .k-note{display:block;margin:6px 0 0 22px;width:calc(100% - 22px);box-sizing:border-box;font:inherit;font-size:.85em;color:inherit;
          padding:5px 10px;border-radius:6px;border:0;background:color-mix(in srgb,currentColor 5%,transparent)}
        .k-note[hidden]{display:none}
        .k-note:focus{outline:2px solid var(--k-acc)}
        .k-bar{position:fixed;left:50%;bottom:16px;transform:translateX(-50%);display:flex;align-items:center;gap:10px;height:40px;
          box-sizing:border-box;padding:0 6px 0 14px;border-radius:20px;background:var(--bg);
          border:1px solid color-mix(in srgb,currentColor 12%,transparent);box-shadow:0 2px 6px rgba(0,0,0,.2);white-space:nowrap;font-size:13px}
        .k-dots{display:flex;gap:4px}
        .k-pd{width:8px;height:8px;padding:0;border:0;border-radius:4px;background:color-mix(in srgb,currentColor 18%,transparent);cursor:pointer}
        .k-pd.on{background:var(--k-acc)}
        .k-sum{font-family:ui-monospace,monospace;font-size:12px;font-variant-numeric:tabular-nums}
        .k-sep{width:1px;height:18px;background:color-mix(in srgb,currentColor 12%,transparent)}
        .k-ok{font-size:12px;font-weight:500;color:var(--muted)}
        .k-pill{height:26px;padding:0 10px;border:0;border-radius:13px;background:color-mix(in srgb,currentColor 7%,transparent);
          color:inherit;font:12px -apple-system,sans-serif;cursor:pointer}
        .k-pill:hover{background:color-mix(in srgb,currentColor 11%,transparent)}
        .k-send{height:28px;padding:0 12px;border:0;border-radius:14px;background:var(--k-acc);color:#fff;font:500 12px -apple-system,sans-serif;cursor:pointer}
        .k-send:disabled{opacity:.4;cursor:default}
        .k-keys{position:fixed;top:10px;right:14px;font:11px -apple-system,sans-serif;color:var(--muted)}
        @media (prefers-reduced-motion:reduce){.k-opt{transition:none}}
        @media print{.k-bar,.k-keys,.k-addnote{display:none}}
        </style>
        """

    /// The JavaScript that handles the page's clicks and keys. It runs beside the page (`MarkdownTab.world`).
    static let script = """
        const post = m => webkit.messageHandlers.kelpSync?.postMessage(m);
        document.querySelectorAll('.k-opt').forEach(b => b.addEventListener('click', () => post({ kind: 'pick', point: b.dataset.p, key: b.dataset.k })));
        document.querySelectorAll('.k-note').forEach(i => {
          const save = () => post({ kind: 'note', point: i.dataset.p, text: i.value });
          i.addEventListener('change', save);
          i.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.metaKey) i.blur(); });
        });
        document.querySelectorAll('.k-addnote').forEach(b => b.addEventListener('click', () => {
          const i = b.nextElementSibling; b.remove(); i.hidden = false; i.focus();
        }));
        const points = [...document.querySelectorAll('.k-point')];
        let current = points.find(p => !p.querySelector('.k-opt.on')) || points[0];
        const show = p => {
          if (!p) return;
          current = p; points.forEach(q => q.classList.toggle('k-at', q === p));
          p.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        };
        document.querySelectorAll('.k-pd').forEach(d => d.addEventListener('click', () => show(document.getElementById('p' + d.dataset.go))));
        document.querySelector('.k-send')?.addEventListener('click', () => post({ kind: 'send' }));
        document.querySelector('.k-rest')?.addEventListener('click', () => post({ kind: 'recommended' }));
        document.querySelector('.k-unsend')?.addEventListener('click', () => post({ kind: 'unsend' }));
        addEventListener('keydown', e => {
          if (e.key === 'Enter' && e.metaKey) {
            document.activeElement?.blur?.();
            if (document.querySelector('.k-send:not(:disabled)')) post({ kind: 'send' });
            return e.preventDefault();
          }
          if (e.target.closest?.('input, textarea') || e.metaKey || e.ctrlKey || e.altKey) return;
          if (/^[1-9]$/.test(e.key)) { show(document.getElementById('p' + e.key)); return e.preventDefault(); }
          const k = e.key.toUpperCase();
          const b = /^[A-Z]$/.test(k) && current && current.querySelector('.k-opt[data-k="' + k + '"]:not(:disabled)');
          if (b) { b.click(); e.preventDefault(); }
        });
        """

    /// Renders a line of inline Markdown (code, emphasis, links), without the paragraph around it.
    private static func inline(_ text: String) -> String {
        let html = MarkdownHTML.render(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard html.hasPrefix("<p>"), html.hasSuffix("</p>") else { return html }
        return String(html.dropFirst(3).dropLast(4))
    }
}
