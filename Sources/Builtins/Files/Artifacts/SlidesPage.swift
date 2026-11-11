import Core
import Foundation

/// An agent's slides (`slides.md`): the Markdown page cut at its rules (`---`) into 16:9 slides, a strip of them on the
/// left and one at a time beside it; ← → (space, Page Up/Down) step, a click on the strip goes there. Each slide's
/// layout comes from what it holds: the first is the title, a heading that is a number is a big number, a picture
/// sits beside its text, the rest read as a list. The project's design system (`.kelp/design`) gives the accent and the
/// font, if it has one. `kelpPresent(true)`: one slide as large as the pane, on black, with a strip at the foot.
enum SlidesPage {
    /// The deck's own tokens from the project's `tokens.json`: its accent and its font, in light and dark.
    static func tokens(_ json: String) -> String {
        let css = DesignSystem.css(tokens: json)
        func pick(_ vars: String) -> String {
            vars.split(separator: ";").compactMap { part -> String? in
                let d = part.trimmingCharacters(in: .whitespaces)
                for (from, to) in [
                    ("--accent:", "--deck-accent:"), ("--font-body:", "--deck-font:"),
                    ("--font-display:", "--deck-display:")
                ] where d.hasPrefix(from) {
                    return to + d.dropFirst(from.count) + ";"
                }
                return nil
            }.joined()
        }
        let light = pick(css.light), dark = pick(css.dark)
        guard !light.isEmpty else { return "" }
        return "<style>:root{\(light)}@media (prefers-color-scheme:dark){:root{\(dark)}}:root.dark{\(dark)}</style>"
    }

    static let style = """
        <style>
        html{background:var(--subtle)}
        body{margin:0}
        .markdown-body{max-width:none;padding:0;margin:0}
        .kelp-deck{display:flex;height:100vh}
        .kelp-thumbs{width:150px;flex:none;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:12px;
          border-right:1px solid var(--border);background:var(--bg)}
        .kelp-thumb{display:flex;gap:6px;align-items:flex-start;border:0;background:none;padding:0;color:var(--muted);
          font:10px/1.2 -apple-system,sans-serif;font-variant-numeric:tabular-nums;cursor:default}
        .kelp-thumb span{width:10px;flex:none;text-align:right}
        .kelp-thumb .slide{width:112px !important;border-radius:4px;pointer-events:none;display:block;text-align:left}
        .kelp-thumb.on .slide{box-shadow:0 0 0 2.5px var(--k-accent,#007aff)}
        .kelp-stage{flex:1;min-width:0;display:flex;flex-direction:column;align-items:center;justify-content:center;
          gap:10px}
        .kelp-stage>.slide{display:none}.kelp-stage>.slide.on{display:block}
        .kelp-at{font:12px -apple-system,sans-serif;color:var(--muted);font-variant-numeric:tabular-nums}
        .slide{--acc:var(--deck-accent,#007aff);container-type:inline-size;position:relative;aspect-ratio:16/9;
          flex:none;
          background:var(--bg);border:1px solid var(--border);border-radius:10px;overflow:hidden;
          font-family:var(--deck-font,-apple-system,BlinkMacSystemFont,sans-serif)}
        .slide-body{position:absolute;inset:0;padding:6cqw 8cqw;display:flex;flex-direction:column;
          justify-content:center;
          font-size:2.6cqw;line-height:1.4}
        .slide-body h1,.slide-body h2{border:0;padding:0;margin:0 0 .5em;font-family:var(--deck-display,inherit);
          letter-spacing:-.01em}
        .slide-body h1{font-size:2.4em}.slide-body h2{font-size:1.7em}
        .slide-body>:last-child{margin-bottom:0}
        .slide-body li::marker{color:var(--acc)}
        .k-title .slide-body h1{font-size:3.4em;margin-bottom:.25em}
        .k-title .slide-body h1::before{content:"";display:block;width:1.1em;height:.12em;background:var(--acc);
          margin-bottom:.45em}
        .k-title .slide-body p{font-size:1.3em;color:var(--muted)}
        .k-number .slide-body h1,.k-number .slide-body h2{font-size:6em;line-height:1;color:var(--acc);
          margin-bottom:.2em}
        .k-number .slide-body p{font-size:1.3em;color:var(--muted)}
        .k-picture .slide-body{display:grid;grid-template-columns:1fr 1fr;column-gap:5cqw;align-content:center}
        .k-picture .slide-body>p:has(img){grid-column:2;grid-row:1/span 20;margin:0;align-self:center}
        .k-picture .slide-body img{width:100%;max-height:70cqw;object-fit:contain;border-radius:1cqw}
        .kelp-present .kelp-thumbs,.kelp-present .kelp-at{display:none}
        .kelp-present .kelp-stage{background:#000;padding-bottom:64px}
        .kelp-present .kelp-stage>.slide{border:0;border-radius:0}
        @page{size:landscape;margin:0}
        @media print{html{background:none}.kelp-deck{display:block;
          height:auto}.kelp-thumbs,.kelp-at,.kelp-strip{display:none !important}
          .kelp-stage{display:block}.kelp-stage>.slide{display:block;width:100% !important;margin:0;border:0;
            border-radius:0;break-after:page}}
        </style>
        """

    /// `labels`: of, escEnds. JavaScript, run beside the page (`MarkdownTab.world`), after `scrollSync`, whose
    /// `kelpToLine` it takes over: the source's line shows its slide, and a slide shown moves the source to it.
    static func script(labels: [String: String]) -> String {
        """
        (function () {
          const page = document.querySelector('.markdown-body'); if (!page) return;
          const L = \(MarkdownTab.js(labels)), post = m => webkit.messageHandlers.kelpSync?.postMessage(m);
          const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls;
            if (text != null) e.textContent = text; return e; };
          const groups = [[]];
          for (const b of [...page.children]) { if (b.tagName === 'HR') groups.push([]);
            else groups[groups.length - 1].push(b); }
          const shown = groups.filter(g => g.some(b => !b.hasAttribute('data-line') || b.textContent.trim()));
          const slides = shown.map((g, i) => {
            const s = el('section', 'slide'), body = el('div', 'slide-body');
            body.append(...g); s.append(body);
            const head = body.querySelector('h1, h2'), words = head ? head.textContent.trim() : '';
            if (i === 0) s.classList.add('k-title');
            else if (words.length <= 12 && /^[~≈<>+−-]?[$€£]?\\d/.test(words)) s.classList.add('k-number');
            else if (body.querySelector('img') && body.textContent.trim()) s.classList.add('k-picture');
            return s;
          });
          const deck = el('div', 'kelp-deck'), thumbs = el('nav', 'kelp-thumbs'), stage = el('main', 'kelp-stage');
          const where = el('div', 'kelp-at');
          page.replaceChildren(deck);
          deck.append(thumbs, stage);
          stage.append(...slides, where);
          slides.forEach((s, i) => {
            const t = el('button', 'kelp-thumb');
            t.append(el('span', null, String(i + 1)), s.cloneNode(true));
            t.onclick = () => go(i, true);
            thumbs.append(t);
          });
          window.kelpSlides = slides;
          const strip = el('div', 'kelp-strip'), back = el('button', 'kelp-ib', '‹'), next = el('button', 'kelp-ib',
            '›');
          const at2 = el('span', 'kelp-where');
          back.onclick = () => go(at - 1, true); next.onclick = () => go(at + 1, true);
          strip.append(back, at2, next, el('span', 'kelp-sep'), el('span', 'kelp-esc', L.escEnds));
          document.body.append(strip);
          let at = 0, presenting = false, quiet = null;
          const wake = () => {
            strip.classList.add('on'); clearTimeout(quiet);
            quiet = setTimeout(() => strip.classList.remove('on'), 2000);
          };
          addEventListener('mousemove', () => { if (presenting) wake(); });
          function size() {
            const w = presenting ? innerWidth : stage.clientWidth - 64;
            const h = presenting ? innerHeight - 64 : stage.clientHeight - 90;
            const width = Math.max(160, Math.min(w, h * 16 / 9));
            for (const s of slides) s.style.width = width + 'px';
          }
          const lineOf = s => +(s.querySelector('[data-line]')?.dataset.line || 0);
          function go(i, user) {
            if (!slides.length) return;
            at = window.kelpAt = Math.max(0, Math.min(slides.length - 1, i));
            slides.forEach((s, j) => s.classList.toggle('on', j === at));
            [...thumbs.children].forEach((t, j) => t.classList.toggle('on', j === at));
            thumbs.children[at].scrollIntoView({ block: 'nearest' });
            where.textContent = at2.textContent = (at + 1) + ' ' + L.of + ' ' + slides.length;
            if (user && lineOf(slides[at])) post({ kind: 'scroll', line: lineOf(slides[at]) });
            dispatchEvent(new CustomEvent('kelp-slide'));
          }
          window.kelpToLine = n => {
            let i = 0;
            slides.forEach((s, j) => { if (lineOf(s) && lineOf(s) <= n) i = j; });
            go(i, false);
          };
          window.kelpGo = i => go(i, false);
          window.kelpPresent = on => {
            presenting = on;
            document.body.classList.toggle('kelp-present', on);
            size();
            if (on) wake();
          };
          addEventListener('keydown', e => {
            if (e.target.closest?.('input, textarea')) return;
            const d = { ArrowRight: 1, ArrowDown: 1, PageDown: 1, ' ': 1, ArrowLeft: -1, ArrowUp: -1,
              PageUp: -1 }[e.key];
            if (e.key === 'Escape' && presenting) { kelpPresent(false); post({ kind: 'present' });
              e.preventDefault(); return; }
            if (!d) return;
            e.preventDefault(); go(at + d, true); if (presenting) wake();
          });
          addEventListener('resize', size);
          new ResizeObserver(() => requestAnimationFrame(size)).observe(stage);
          size();
          go(0, false);
        })();
        """
    }
}
