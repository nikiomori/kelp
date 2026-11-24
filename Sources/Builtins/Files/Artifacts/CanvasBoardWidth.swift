import Foundation

/// A board seen narrower than drawn (v0's resize, Figma Sites' breakpoints): its name row has 390 · 768 · 1280 (those
/// under its own width) and As Drawn, and a grip on its right edge drags it to any width. Both themes' frames take the
/// width; it is a way of looking, not a change to the board. A mark made at a width other than the board's own
/// remembers it (`width`), says it to the agent ("at 390px wide"), and shows the board at it again. Check looks at
/// each board at those widths too, after drawing it as it is: text cut off and content wider than the board, said
/// with the width ("boards/A.html @390: …"), which `kelp artifact check --width 390` picks out.
enum CanvasBoardWidth {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas, M = window.kelpMarks; if (!K) return;
          // A motion page's stage and a dashboard have a size of their own to keep.
          if (document.body.matches('.kelp-motion-page, .kelp-dash')) return;
          const sizes = [390, 768, 1280], now = {};   // the width shown, by board, when not its own
          const ownOf = f => +(f.dataset.own || f.dataset.w);
          const frames = board => K.frames.filter(f => f.dataset.board === board);
          // Lays `f` out at `w` (its own when 0); a board without a height of its own grows with what's in it.
          function lay(f, w) {
            if (!f.dataset.own) f.dataset.own = f.dataset.w;
            const width = w || ownOf(f);
            f.dataset.w = width; f.style.width = width + 'px';
            const body = f.contentDocument?.body;
            if (!f.dataset.h && body)
              f.style.height = Math.max(60, Math.ceil(body.getBoundingClientRect().height)) + 'px';
          }
          function show(board, w) {
            const f0 = frames(board)[0]; if (!f0) return;
            if (w && w === ownOf(f0)) w = 0;
            for (const f of frames(board)) lay(f, w);
            if (w) now[board] = w; else delete now[board];
            for (const b of document.querySelectorAll('.kelp-widths[data-board="' + CSS.escape(board) + '"] button'))
              b.classList.toggle('on', +b.dataset.w === w);
            window.kelpFit?.(); window.kelpOutline?.(); M?.draw?.();
          }
          window.kelpBoardWidth = show;
          function setUp(f) {
            const name = f.closest('.frame')?.querySelector('.name'), own = ownOf(f);
            if (!name || f.dataset.theme === 'dark' || own <= sizes[0] || name.querySelector('.kelp-widths')) return;
            const board = f.dataset.board, seg = K.el('span', 'kelp-seg kelp-widths');
            seg.dataset.board = board;
            for (const w of sizes.filter(w => w < own).concat([0])) {
              const b = K.el('button', w === (now[board] || 0) ? 'on' : '', w ? String(w) : L.asDrawn);
              b.dataset.w = w;
              b.onclick = e => { e.stopPropagation(); show(board, w); };
              seg.append(b);
            }
            name.append(seg);
            // The grip: dragged, the board follows the pointer, from 280 points to twice its own width.
            const grip = K.el('div', 'kelp-wgrip');
            grip.title = L.drag;
            grip.addEventListener('pointerdown', e => {
              e.preventDefault(); e.stopPropagation(); grip.setPointerCapture(e.pointerId);
              const start = e.clientX, from = +f.dataset.w, z = window.kelpZoomNow || 1;
              const move = ev =>
                show(board, Math.round(Math.max(280, Math.min(own * 2, from + (ev.clientX - start) / z))));
              grip.addEventListener('pointermove', move);
              grip.addEventListener('pointerup', () => grip.removeEventListener('pointermove', move), { once: true });
            });
            f.closest('.frame').append(grip);
          }
          for (const f of K.frames) {
            f.addEventListener('load', () => setUp(f));
            if (f.contentDocument?.readyState === 'complete') setUp(f);
          }
          // Check, at each narrower width: what doesn't fit there. The board is put back as it was shown.
          const named = el => {
            const d = el.closest('[data-id]');
            return d ? '[data-id=' + d.getAttribute('data-id') + ']' : el.tagName.toLowerCase();
          };
          (window.kelpCheckMore = window.kelpCheckMore || []).push(out => {
            for (const f of K.frames) {
              const doc = f.contentDocument, own = ownOf(f), shown = +f.dataset.w, height = f.style.height;
              if (f.dataset.theme === 'dark' || !doc?.body) continue;
              for (const w of sizes.filter(w => w < own)) {
                lay(f, w);
                const at = f.dataset.board + ' @' + w + ': ', root = doc.documentElement, win = doc.defaultView;
                if (root.scrollWidth > w + 1)
                  out.push(at + 'content is ' + root.scrollWidth + 'px wide, the board ' + w);
                for (const el of doc.body.querySelectorAll('*')) {
                  const st = win.getComputedStyle(el);
                  const text = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
                  if (text && ['hidden', 'clip'].includes(st.overflowX) && el.scrollWidth > el.clientWidth + 1)
                    out.push(at + 'text is cut off in ' + named(el));
                }
              }
              lay(f, shown === own ? 0 : shown);
              f.style.height = height;
            }
          });
          if (!M) return;
          const add = M.add.bind(M);
          M.add = m => { if (m.board && now[m.board]) m.width = now[m.board]; add(m); };
          const hooks = K.hooks, what = hooks.what, focus = hooks.focus;
          hooks.what = m => what(m) + (m.width ? ' · @' + m.width : '');
          hooks.focus = m => { if (m.board) show(m.board, m.width || 0); focus(m); };
        """

    static let style = """
        .kelp-widths { margin-left: 8px; vertical-align: middle; font-size: calc(10px / var(--z, 1)); }
        .frame:has(.kelp-wgrip) { position: relative; }
        .kelp-wgrip { position: absolute; right: calc(-12px / var(--z, 1)); top: 50%; width: calc(5px / var(--z, 1));
          height: calc(44px / var(--z, 1)); border-radius: 3px; background: var(--k-accent); cursor: ew-resize;
          opacity: 0; transition: opacity .15s; }
        .frame:hover .kelp-wgrip, .kelp-wgrip:active { opacity: 1; }
        """
}
