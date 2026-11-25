import DesignKit
import Foundation

/// The controls Kelp puts around a canvas's boards, inside the page (`MarkdownTab.world`). They are the column on the
/// right that Mark and Edit fill (`window.kelpColumn`) and the zoom capsule at the bottom right (− % + and Fit); the
/// themes are in ⋯ › View. They are drawn with Kelp's own tokens, in the window's light or dark look. They send `zoom`
/// (a size, or null for Fit) to `kelpSync`, and the tab keeps it for the next drawing. Without `floats` (a doc's page,
/// a dashboard), only the column is added.
enum CanvasChrome {
    struct Labels {
        var fit: String, zoomOut: String, zoomIn: String
    }

    static func source(labels l: Labels, floats: Bool = true) -> String {
        let js: (String) -> String = MarkdownTab.js
        return """
            (function () {
              const post = m => webkit.messageHandlers.kelpSync?.postMessage(m);
              const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls;
                if (text != null) e.textContent = text; return e; };
              // The column: a head (a title or a switch, then buttons) and a body; open while Mark or Edit is on.
              const col = el('aside', 'kelp-col'), head = el('div', 'kelp-col-head'), body = el('div', 'kelp-col-body');
              const band = el('div', 'kelp-col-band');   // over the head, when there's something to say
              col.append(band, head, body);
              document.body.append(col);
              window.kelpColumn = {
                open(heads, nodes, bands = []) {
                  head.replaceChildren(...heads); body.replaceChildren(...nodes); band.replaceChildren(...bands);
                  band.style.display = bands.length ? 'flex' : 'none';
                  if (!document.body.classList.contains('kelp-with-col')) {
                    document.body.classList.add('kelp-with-col'); window.kelpFit?.();
                  }
                },
                close() {
                  if (!document.body.classList.contains('kelp-with-col')) return;
                  document.body.classList.remove('kelp-with-col'); window.kelpFit?.();
                },
                // A switch of [key, name] pairs with `current` on; a click calls `pick` with the key.
                tabs(list, current, pick) {
                  const seg = el('span', 'kelp-seg');
                  for (const [key, name] of list) {
                    const b = el('button', key === current ? 'on' : '', name);
                    b.onclick = () => pick(key);
                    seg.append(b);
                  }
                  return seg;
                },
                el, post
              };
              // The empty state's actions (canvas.json that doesn't read): open the file, or ask its agent.
              for (const b of document.querySelectorAll('[data-kelp]'))
                b.onclick = () => post({ kind: b.dataset.kelp, why: b.dataset.why || '' });
              // The boards the agent's last turn changed, outlined until the next click on the canvas.
              window.kelpTouched = list => {
                for (const f of document.querySelectorAll('iframe[data-board]'))
                  f.closest('.frame')?.classList.toggle('kelp-touched', list.includes(f.dataset.board));
                addEventListener('mousedown', () => window.kelpTouched([]), { once: true });
              };
              if (!\(floats)) return;
              // The canvas's size: steps down and up, or fitted to the pane.
              const zoom = el('div', 'kelp-float kelp-zoom');
              const out = el('button', 'kelp-ib'), into = el('button', 'kelp-ib');
              out.innerHTML = \(PageSymbols.span("minus")); into.innerHTML = \(PageSymbols.span("plus"));
              const shown = el('span', 'kelp-pct'), fit = el('button', 'kelp-pill', \(js(l.fit)));
              out.title = \(js(l.zoomOut)); into.title = \(js(l.zoomIn));
              const steps = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.25, 1.5, 2];
              const set = z => { window.kelpZoom(z); post({ kind: 'zoom', value: z }); };
              const now = () => window.kelpZoomNow || 1;
              out.onclick = () => set([...steps].reverse().find(s => s < now() - 0.001) || steps[0]);
              into.onclick = () => set(steps.find(s => s > now() + 0.001) || steps[steps.length - 1]);
              fit.onclick = () => set(null);
              zoom.append(out, shown, into, el('span', 'kelp-sep'), fit);
              addEventListener('kelp-zoom', () => { shown.textContent = Math.round(now() * 100) + '%'; });
              document.body.append(zoom);
              // Keys as in design tools: ⌘+ ⌘− step, ⌘9 fits, ⇧2 brings the chosen element into view, large.
              const typing = t => t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName);
              const scaleOf = f => f.getBoundingClientRect().width / f.offsetWidth;
              function bringIn(at) {
                const r = at.e.getBoundingClientRect();
                const fits = Math.min(innerWidth / r.width, innerHeight / r.height) * 0.6;
                set(Math.min(4, now() * fits / scaleOf(at.f)));
                requestAnimationFrame(() => {
                  const b = at.e.getBoundingClientRect(), g = at.f.getBoundingClientRect(), k = scaleOf(at.f);
                  scrollBy(g.left + (b.left + b.width / 2) * k - innerWidth / 2,
                    g.top + (b.top + b.height / 2) * k - innerHeight / 2);
                });
              }
              addEventListener('keydown', e => {
                if (typing(e.target)) return;
                const key = e.metaKey && !e.altKey ? { '=': into, '+': into, '-': out, '9': fit }[e.key] : null;
                if (key) { e.preventDefault(); return key.click(); }
                const at = e.shiftKey && !e.metaKey && e.code === 'Digit2' && window.kelpProps?.at?.();
                if (at) { e.preventDefault(); bringIn(at); }
              });
              // Space held: the canvas moves with the pointer (not in Mark, where Space shows Before, nor presenting).
              let panning = null;
              const ownSpace = () => window.kelpCanvas?.mode?.() === 'mark'
                || document.body.classList.contains('kelp-present');
              addEventListener('keydown', e => {
                if (e.code !== 'Space' || typing(e.target) || panning || ownSpace()) return;
                e.preventDefault(); panning = { at: null }; document.body.style.cursor = 'grab';
              });
              addEventListener('keyup', e => {
                if (e.code !== 'Space') return;
                panning = null; document.body.style.cursor = '';
              });
              addEventListener('mousedown', e => {
                if (!panning) return;
                panning.at = [e.clientX, e.clientY]; e.preventDefault(); e.stopPropagation();
              }, true);
              addEventListener('mousemove', e => {
                if (!panning?.at) return;
                scrollBy(panning.at[0] - e.clientX, panning.at[1] - e.clientY);
                panning.at = [e.clientX, e.clientY];
              }, true);
              addEventListener('mouseup', () => { if (panning) panning.at = null; }, true);
            })();
            """
    }

    /// DesignKit's text sizes, radii and durations as the page's CSS variables (`--k-text-caption`, `--k-radius-md`,
    /// `--k-fast`), so what Kelp draws on a page is sized and moves as the window around it does.
    static let sizes =
        [
            ("title", TextSize.title), ("heading", TextSize.heading), ("body", TextSize.body), ("row", TextSize.row),
            ("caption", TextSize.caption), ("micro", TextSize.micro)
        ].map { "--k-text-\($0.0): \(Int($0.1))px;" }.joined(separator: " ") + " "
        + [
            ("xs", Metrics.radiusXS), ("sm", Metrics.radiusSM), ("md", Metrics.radiusMD), ("lg", Metrics.radiusLG),
            ("xl", Metrics.radiusXL)
        ].map { "--k-radius-\($0.0): \(Int($0.1))px;" }.joined(separator: " ")
        + " --k-radius-capsule: 999px; --k-icon: \(Int(Metrics.iconPoint))px; "
        + [("fast", Motion.fast), ("base", Motion.base), ("slow", Motion.slow), ("appear", Motion.appear)]
        .map { "--k-\($0.0): \(Int($0.1 * 1000))ms;" }.joined(separator: " ")

    /// Kelp's tokens in dark: the page's in a dark window, and always the speaker's window (as Keynote's is).
    static let dark = """
        --k-ground: #232325; --k-win: #363a3c; --k-card: #282828; --k-label: rgba(255,255,255,.85);
          --k-sec: rgba(255,255,255,.55); --k-sep: rgba(255,255,255,.1); --k-rest: rgba(255,255,255,.05);
          --k-hover: rgba(255,255,255,.08); --k-sel: rgba(255,255,255,.12); --k-accent: #0a84ff;
          --k-float: rgba(48,48,50,.96); --k-orange: #ff9f0a; --k-text-orange: #ff9f0a;
          --k-quiet: #636366; --k-purple: #bf5af2; --k-knob: #e5e5e7; --k-red: #ff453a; --k-text-red: #ff6961;
          --k-guide: #ff375f; --k-shadow-raised: none;
        """

    /// The CSS for what Kelp draws on the page: Kelp's tokens in light and dark (following the window's appearance),
    /// and the style of each control.
    static let style = """
        :root { --k-ground: #f2f2f2; --k-win: #eaeced; --k-card: #fff; --k-label: rgba(0,0,0,.85);
          --k-sec: rgba(0,0,0,.5); --k-sep: rgba(0,0,0,.1); --k-rest: rgba(0,0,0,.05); --k-hover: rgba(0,0,0,.08);
          --k-sel: rgba(0,0,0,.12); --k-accent: #007aff; --k-float: rgba(246,246,246,.96); --k-orange: #ff9500;
          --k-text-orange: #9a5000; --k-quiet: #aeaeb2; --k-purple: #af52de; --k-knob: #fff;
          --k-red: #ff3b30; --k-text-red: #d70015; --k-guide: #ff2d55; --k-on-orange: #1d1d1f; --k-on-accent: #fff;
          --k-hud: rgba(40,40,40,.85); --k-on-hud: rgba(255,255,255,.85); --k-on-hud-sec: rgba(255,255,255,.6);
          --k-hud-sep: rgba(255,255,255,.2);
          --k-shadow-raised: 0 .5px 2px rgba(0,0,0,.12);
          --k-shadow-float-sm: 0 0 0 .5px var(--k-sep), 0 2px 6px rgba(0,0,0,.2);
          --k-shadow-float: 0 0 0 .5px var(--k-sep), 0 0 14px rgba(0,0,0,.3);
          \(sizes) }
        @media (prefers-color-scheme: dark) { :root { \(dark) } }
        body.kelp-with-col { padding-right: 300px; }
        .kelp-col { position: fixed; top: 0; right: 0; bottom: 0; width: 260px; display: none; flex-direction: column;
          background: var(--k-win); border-left: 1px solid var(--k-sep); z-index: 20; color: var(--k-label);
          font: var(--k-text-row)/1.35 -apple-system, BlinkMacSystemFont, sans-serif; }
        .kelp-with-col .kelp-col { display: flex; }
        .kelp-col-head { height: 36px; flex: none; display: flex; align-items: center; gap: 6px; padding: 0 8px 0 12px;
          border-bottom: 1px solid var(--k-sep); font-size: var(--k-text-body); font-weight: 600; }
        .kelp-col-body { flex: 1; overflow-y: auto; padding-bottom: 12px; }
        .kelp-sec { font-size: var(--k-text-caption); font-weight: 600; color: var(--k-sec); padding: 12px 12px 6px; }
        .kelp-row { display: flex; align-items: center; gap: 8px; padding: 4px 12px; }
        .kelp-row > span:first-child { flex: none; }
        .kelp-grow { flex: 1; }
        .kelp-note { color: var(--k-sec); font-size: var(--k-text-caption); padding: 10px 12px; }
        .kelp-float { position: fixed; z-index: 17;   /* over the sheet (15) and the guides (16) */
          display: flex; align-items: center; gap: 2px; padding: 0 4px;
          height: 30px; border-radius: var(--k-radius-md); background: var(--k-float); color: var(--k-label);
          box-shadow: var(--k-shadow-float-sm); font: var(--k-text-row) -apple-system, sans-serif; }
        .kelp-zoom { bottom: 14px; right: 14px; }
        .kelp-with-col .kelp-zoom { right: 274px; }
        .kelp-seg { display: inline-flex; height: 22px; padding: 2px; box-sizing: border-box;
          border-radius: var(--k-radius-capsule);
          background: var(--k-rest); gap: 2px; }
        .kelp-seg button { height: 18px; padding: 0 9px; border: 0; border-radius: var(--k-radius-capsule);
          background: none; color: var(--k-sec); font: inherit; }
        .kelp-seg button.on { background: var(--k-card); color: var(--k-label);
          box-shadow: var(--k-shadow-raised); }
        .kelp-ib { width: 22px; height: 22px; border: 0; border-radius: var(--k-radius-sm); background: none;
          color: var(--k-sec);
          font: var(--k-icon) -apple-system, sans-serif; }
        .kelp-ib:hover { background: var(--k-hover); }
        .kelp-pill [class*="kelp-sym-"] { margin-right: 4px; }
        .kelp-pill { height: 22px; padding: 0 8px; border: 0; border-radius: var(--k-radius-capsule);
          background: var(--k-rest);
          color: var(--k-label); font: inherit; }
        .kelp-pill:hover { background: var(--k-hover); }
        .kelp-prominent { height: 24px; padding: 0 12px; border: 0; border-radius: var(--k-radius-sm);
          background: var(--k-accent);
          color: var(--k-on-accent); font: 500 var(--k-text-row) -apple-system, sans-serif; }
        .kelp-pct { width: 40px; text-align: center; font-variant-numeric: tabular-nums; }
        .kelp-sep { width: 1px; height: 16px; background: var(--k-sep); margin: 0 4px; }
        .kelp-issues { position: absolute; inset: 0 auto auto 0; pointer-events: none; z-index: 9; }
        .kelp-fault { position: absolute; width: 16px; height: 16px; border-radius: var(--k-radius-xs);
          background: var(--k-card);
          color: var(--k-text-orange); box-shadow: 0 0 0 1px var(--k-orange);
          display: flex; align-items: center; justify-content: center; pointer-events: auto; cursor: default; }
        .kelp-present .kelp-col, .kelp-present .kelp-float, .kelp-present .kelp-issues { display: none !important; }
        .frame.kelp-touched iframe { box-shadow: 0 0 0 2px var(--k-orange); }
        .kelp-ib, .kelp-pill, .kelp-prominent, .kelp-seg button, .kelp-toc, .kelp-ebtn, .kelp-ipop, .kelp-ireset,
          .kelp-ilink, .kelp-lrow, .kelp-lbtn, .kelp-suggest, .kelp-cv-tile, .kelp-pick, .kelp-tweaks, .kelp-anchor,
          .kelp-markbtn { transition: background var(--k-fast) ease-out, color var(--k-fast) ease-out,
            filter var(--k-fast) ease-out; }
        .kelp-seg button:not(.on):hover { background: var(--k-hover); }
        .kelp-prominent:hover, .kelp-markbtn:hover { filter: brightness(1.08); }
        .kelp-ib:active, .kelp-pill:active, .kelp-seg button:not(.on):active, .kelp-toc:active, .kelp-ebtn:active,
          .kelp-ipop:active, .kelp-ireset:active, .kelp-ilink:active, .kelp-lbtn:active, .kelp-suggest:active,
          .kelp-cv-tile:not(.on):active, .kelp-pick:active, .kelp-tweaks:active, .kelp-anchor:active {
          background: var(--k-sel); transition: none; }
        .kelp-lrow:not(.on):active { background: var(--k-sel); transition: none; }
        .kelp-prominent:active, .kelp-markbtn:active { filter: brightness(.88); transition: none; }
        .kelp-cv-tile:not(.on):hover, .kelp-pick:hover, .kelp-tweaks:hover, .kelp-anchor:hover {
          background: var(--k-hover); color: var(--k-label); }
        [class*="kelp-"]:disabled { color: var(--k-quiet); background: none; filter: none; }
        @media (prefers-reduced-motion: reduce) {
          [class*="kelp-"], [class*="kelp-"]::before, [class*="kelp-"]::after {
            transition: none !important; animation: none !important; } }
        @keyframes kelp-spin { to { transform: rotate(360deg); } }
        """
}
