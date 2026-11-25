import Foundation

/// Several elements at once in Edit (as in any design tool): ⇧-click adds an element of the same board to the chosen
/// one, or takes it out; the arrows move them all, ⌫ takes them all out, and a bar lines them up by an edge or the
/// middle, or spaces them evenly. Each is one hand edit, one ⌘Z (`restyle`, `removeMany`).
enum CanvasMulti {
    static func source(labels: [String: String]) -> String {
        "(function (L, STYLE) {\n" + body + "\n})(\(MarkdownTab.js(labels)), \(MarkdownTab.js(style)));"
    }

    private static let body = """
          const K = window.kelpCanvas; if (!K) return;
          const sheet = K.el('style'); sheet.textContent = STYLE; document.head.append(sheet);
          let group = [], first = null, timer = null;   // the chosen ones besides the first; that one
          const bar = K.el('div', 'kelp-float kelp-multi'), count = K.el('span', 'kelp-multi-n');
          const marks = K.el('div', 'kelp-also-layer');
          document.body.append(bar, marks);
          const all = () => first ? [first, ...group] : [];
          const css = e => e.ownerDocument.defaultView.getComputedStyle(e);
          const moved = e => {
            const n = (css(e).translate.match(/-?[\\d.]+/g) || []).map(Number);
            return [n[0] || 0, n[1] || 0];
          };
          const button = (sym, tip, run) => {
            const b = K.el('button', 'kelp-ib'); b.append(K.el('span', 'kelp-sym-' + sym.replaceAll('.', '-')));
            b.title = tip; b.onclick = run; return b;
          };
          bar.append(count,
            button('align.horizontal.left', L.multiLeft, () => line('x', 0)),
            button('align.horizontal.center', L.multiCentre, () => line('x', 0.5)),
            button('align.horizontal.right', L.multiRight, () => line('x', 1)),
            button('align.vertical.top', L.multiTop, () => line('y', 0)),
            button('align.vertical.center', L.multiMiddle, () => line('y', 0.5)),
            button('align.vertical.bottom', L.multiBottom, () => line('y', 1)),
            button('distribute.horizontal.center', L.multiAcross, () => spread('x')),
            button('distribute.vertical.center', L.multiDown, () => spread('y')));
          function draw() {
            marks.replaceChildren(...group.map(g => {
              const b = K.box(g.f, g.e), d = K.el('div', 'kelp-also');
              Object.assign(d.style, { left: b.x + 'px', top: b.y + 'px', width: b.w + 'px', height: b.h + 'px' });
              return d;
            }));
            bar.style.display = group.length ? 'flex' : 'none';
            count.textContent = L.multiChosen.replace('%d', all().length);
          }
          // Where each is on its board, unscaled.
          const box = g => g.e.getBoundingClientRect();
          function write(moves, what) {
            const board = first.f.dataset.board;
            K.post({ kind: 'restyle', board, what, changes: moves.map(([g, x, y]) => ({ id: K.need(g.f, g.e),
              props: { translate: x + 'px ' + y + 'px' } })) });
          }
          function line(axis, at) {
            const list = all(), b = list.map(box);
            const lo = axis === 'x' ? 'left' : 'top', size = axis === 'x' ? 'width' : 'height';
            const start = Math.min(...b.map(r => r[lo])), end = Math.max(...b.map(r => r[lo] + r[size]));
            const target = at === 0 ? start : at === 1 ? end : (start + end) / 2;
            write(list.map((g, i) => {
              const [x, y] = moved(g.e), d = target - (b[i][lo] + b[i][size] * at);
              return axis === 'x' ? [g, x + d, y] : [g, x, y + d];
            }), 'aligned');
          }
          function spread(axis) {
            const lo = axis === 'x' ? 'left' : 'top', size = axis === 'x' ? 'width' : 'height';
            const list = all().map(g => [g, box(g)]).sort((a, b) => a[1][lo] - b[1][lo]);
            if (list.length < 3) return;
            const span = list[list.length - 1][1][lo] + list[list.length - 1][1][size] - list[0][1][lo];
            const gap = (span - list.reduce((s, [, r]) => s + r[size], 0)) / (list.length - 1);
            let at = list[0][1][lo];
            write(list.map(([g, r]) => {
              const [x, y] = moved(g.e), d = at - r[lo]; at += r[size] + gap;
              return axis === 'x' ? [g, x + d, y] : [g, x, y + d];
            }), 'spaced');
          }
          addEventListener('kelp-chosen', ev => {
            // Another element chosen, or the board drawn again after a change: the group starts again from it.
            group = []; first = ev.detail;
            draw();
          });
          // ⇧-click: an element of the same board joins the chosen, or leaves them.
          K.sheet.addEventListener('mousedown', ev => {
            if (K.mode() !== 'edit' || !ev.shiftKey || !first) return;
            const hit = K.under(ev, false); if (!hit || hit.f !== first.f || hit.e === first.e) return;
            ev.preventDefault(); ev.stopImmediatePropagation();
            const i = group.findIndex(g => g.e === hit.e);
            if (i >= 0) group.splice(i, 1); else group.push(hit);
            draw();
          }, true);
          addEventListener('keydown', ev => {
            if (K.mode() !== 'edit' || !group.length) return;
            const t = ev.target;
            if (t.isContentEditable || /^(INPUT|TEXTAREA)$/.test(t.tagName)) return;
            if (ev.key === 'Escape') { group = []; draw(); return; }
            if (ev.key === 'Backspace' || ev.key === 'Delete') {
              ev.preventDefault(); ev.stopImmediatePropagation();
              K.post({ kind: 'removeMany', board: first.f.dataset.board, ids: all().map(g => K.need(g.f, g.e)) });
              group = []; first = null; return draw();
            }
            const n = ev.shiftKey ? 10 : 1;
            const v = { ArrowLeft: [-n, 0], ArrowRight: [n, 0], ArrowUp: [0, -n], ArrowDown: [0, n] }[ev.key];
            if (!v || ev.metaKey) return;
            ev.preventDefault(); ev.stopImmediatePropagation();
            for (const g of all()) {
              const [x, y] = moved(g.e);
              g.e.style.translate = (x + v[0]) + 'px ' + (y + v[1]) + 'px';
            }
            draw();
            clearTimeout(timer);
            timer = setTimeout(() => write(all().map(g => [g, ...moved(g.e)]), 'moved'), 500);
          }, true);
          addEventListener('kelp-zoom', draw);
          addEventListener('resize', draw);
        """

    static let style = """
        .kelp-multi { top: 14px; left: 50%; transform: translateX(-50%); display: none; }
        .kelp-multi-n { padding: 0 8px; color: var(--k-sec); font-variant-numeric: tabular-nums; }
        .kelp-also-layer { position: absolute; inset: 0 auto auto 0; pointer-events: none; z-index: 8; }
        .kelp-also { position: absolute; box-sizing: border-box; border: 1.5px dashed var(--k-accent); }
        """
}
