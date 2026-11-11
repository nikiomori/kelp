import Foundation

/// What Kelp puts around a canvas's boards, in the page (`MarkdownTab.world`): the column on the right that Mark and
/// Edit fill (`window.kelpColumn`), the theme switch at the top right (one theme at a time, or both), and the zoom
/// capsule at the bottom right (− % + and Fit). Drawn with Kelp's own tokens, in the window's light or dark. To
/// `kelpSync`: `themes` (light, dark or both) and `zoom` (a size, or null for Fit), which the tab keeps for the next
/// drawing. Without `floats` (a doc's page, a dashboard), only the column.
enum CanvasChrome {
    struct Labels {
        var light: String, dark: String, both: String, fit: String, zoomOut: String, zoomIn: String
    }

    static func source(themes: String, labels l: Labels, floats: Bool = true) -> String {
        let js: (String) -> String = MarkdownTab.js
        return """
            (function () {
              const post = m => webkit.messageHandlers.kelpSync?.postMessage(m);
              const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls;
                if (text != null) e.textContent = text; return e; };
              // The column: a head (a title or a switch, then buttons) and a body; open while Mark or Edit is on.
              const col = el('aside', 'kelp-col'), head = el('div', 'kelp-col-head'), body = el('div', 'kelp-col-body');
              col.append(head, body);
              document.body.append(col);
              window.kelpColumn = {
                open(heads, nodes) {
                  head.replaceChildren(...heads); body.replaceChildren(...nodes);
                  if (!document.body.classList.contains('kelp-with-col')) {
                    document.body.classList.add('kelp-with-col'); window.kelpFit?.();
                  }
                },
                close() {
                  if (!document.body.classList.contains('kelp-with-col')) return;
                  document.body.classList.remove('kelp-with-col'); window.kelpFit?.();
                },
                el
              };
              // The empty state's actions (canvas.json that doesn't read): open the file, or ask its agent.
              for (const b of document.querySelectorAll('[data-kelp]'))
                b.onclick = () => post({ kind: b.dataset.kelp, why: b.dataset.why || '' });
              if (!\(floats)) return;
              // One theme at a time, or both side by side: the tab draws the boards again.
              const themes = el('div', 'kelp-float kelp-themes'), seg = el('span', 'kelp-seg');
              for (const [key, name] of [['light', \(js(l.light))], ['dark', \(js(l.dark))], ['both', \(js(l.both))]]) {
                const b = el('button', key === \(js(themes)) ? 'on' : '', name);
                b.onclick = () => post({ kind: 'themes', value: key });
                seg.append(b);
              }
              themes.append(seg);
              // The canvas's size: steps down and up, or fitted to the pane.
              const zoom = el('div', 'kelp-float kelp-zoom');
              const out = el('button', 'kelp-ib', '−'), into = el('button', 'kelp-ib', '+');
              const shown = el('span', 'kelp-pct'), fit = el('button', 'kelp-text', \(js(l.fit)));
              out.title = \(js(l.zoomOut)); into.title = \(js(l.zoomIn));
              const steps = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.25, 1.5, 2];
              const set = z => { window.kelpZoom(z); post({ kind: 'zoom', value: z }); };
              const now = () => window.kelpZoomNow || 1;
              out.onclick = () => set([...steps].reverse().find(s => s < now() - 0.001) || steps[0]);
              into.onclick = () => set(steps.find(s => s > now() + 0.001) || steps[steps.length - 1]);
              fit.onclick = () => set(null);
              zoom.append(out, shown, into, el('span', 'kelp-sep'), fit);
              addEventListener('kelp-zoom', () => { shown.textContent = Math.round(now() * 100) + '%'; });
              document.body.append(themes, zoom);
            })();
            """
    }

    /// Kelp's tokens for what it draws on the page, in light and dark (the window's appearance), and its parts' style.
    static let style = """
        :root { --k-ground: #f2f2f2; --k-win: #eaeced; --k-card: #fff; --k-label: rgba(0,0,0,.85);
          --k-sec: rgba(0,0,0,.5); --k-sep: rgba(0,0,0,.1); --k-rest: rgba(0,0,0,.05); --k-hover: rgba(0,0,0,.08);
          --k-sel: rgba(0,0,0,.12); --k-accent: #007aff; --k-float: rgba(246,246,246,.96); --k-orange: #ff9500;
          --k-text-orange: #9a5000; }
        @media (prefers-color-scheme: dark) {
          :root { --k-ground: #232325; --k-win: #363a3c; --k-card: #282828; --k-label: rgba(255,255,255,.85);
            --k-sec: rgba(255,255,255,.55); --k-sep: rgba(255,255,255,.1); --k-rest: rgba(255,255,255,.05);
            --k-hover: rgba(255,255,255,.08); --k-sel: rgba(255,255,255,.12); --k-accent: #0a84ff;
            --k-float: rgba(48,48,50,.96); --k-orange: #ff9f0a; --k-text-orange: #ff9f0a; }
        }
        body.kelp-with-col { padding-right: 300px; }
        .kelp-col { position: fixed; top: 0; right: 0; bottom: 0; width: 260px; display: none; flex-direction: column;
          background: var(--k-win); border-left: 1px solid var(--k-sep); z-index: 20; color: var(--k-label);
          font: 12px/1.35 -apple-system, BlinkMacSystemFont, sans-serif; }
        .kelp-with-col .kelp-col { display: flex; }
        .kelp-col-head { height: 36px; flex: none; display: flex; align-items: center; gap: 6px; padding: 0 8px 0 12px;
          border-bottom: 1px solid var(--k-sep); font-size: 13px; font-weight: 600; }
        .kelp-col-body { flex: 1; overflow-y: auto; padding-bottom: 12px; }
        .kelp-sec { font-size: 11px; font-weight: 600; color: var(--k-sec); padding: 12px 12px 6px; }
        .kelp-row { display: flex; align-items: center; gap: 8px; padding: 4px 12px; }
        .kelp-row > span:first-child { flex: none; }
        .kelp-grow { flex: 1; }
        .kelp-note { color: var(--k-sec); font-size: 11px; padding: 10px 12px; }
        .kelp-float { position: fixed; z-index: 15; display: flex; align-items: center; gap: 2px; padding: 0 4px;
          height: 30px; border-radius: 12px; background: var(--k-float); color: var(--k-label);
          box-shadow: 0 0 0 .5px var(--k-sep), 0 2px 6px rgba(0,0,0,.2); font: 12px -apple-system, sans-serif; }
        .kelp-themes { top: 10px; right: 14px; }
        .kelp-zoom { bottom: 14px; right: 14px; }
        .kelp-with-col .kelp-themes, .kelp-with-col .kelp-zoom { right: 274px; }
        .kelp-seg { display: inline-flex; height: 22px; padding: 2px; box-sizing: border-box; border-radius: 999px;
          background: var(--k-rest); gap: 2px; }
        .kelp-seg button { height: 18px; padding: 0 9px; border: 0; border-radius: 999px; background: none;
          color: var(--k-sec); font: inherit; }
        .kelp-seg button.on { background: var(--k-card); color: var(--k-label);
          box-shadow: 0 .5px 2px rgba(0,0,0,.12); }
        .kelp-ib { width: 22px; height: 22px; border: 0; border-radius: 6px; background: none; color: var(--k-sec);
          font: 14px -apple-system, sans-serif; }
        .kelp-ib:hover, .kelp-text:hover { background: var(--k-hover); }
        .kelp-text { height: 22px; padding: 0 8px; border: 0; border-radius: 999px; background: none;
          color: var(--k-label); font: inherit; }
        .kelp-pill { height: 22px; padding: 0 8px; border: 0; border-radius: 999px; background: var(--k-rest);
          color: var(--k-label); font: inherit; }
        .kelp-pill:hover { background: var(--k-hover); }
        .kelp-prominent { height: 24px; padding: 0 12px; border: 0; border-radius: 6px; background: var(--k-accent);
          color: #fff; font: 500 12px -apple-system, sans-serif; }
        .kelp-pct { width: 40px; text-align: center; font-variant-numeric: tabular-nums; }
        .kelp-sep { width: 1px; height: 16px; background: var(--k-sep); margin: 0 4px; }
        .kelp-issues { position: absolute; inset: 0 auto auto 0; pointer-events: none; z-index: 9; }
        .kelp-fault { position: absolute; width: 16px; height: 16px; border-radius: 4px; background: var(--k-card);
          color: var(--k-text-orange); box-shadow: 0 0 0 1px var(--k-orange);
          font: 700 10px/16px -apple-system, sans-serif;
          text-align: center; pointer-events: auto; cursor: default; }
        .kelp-present .kelp-col, .kelp-present .kelp-float, .kelp-present .kelp-issues { display: none !important; }
        """
}
