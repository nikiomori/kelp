import Foundation

/// Cropping a picture or a video by hand in Edit, on a board or a motion page's stage. A double click on one (or Crop
/// in its menu, `kelpCrop()`) shows a handle on each side of what shows: a side dragged cuts it, a drag in the middle
/// moves the cut over the picture. A bar under it offers Free, 16:9, 1:1, 4:5 and Reset; Esc or ↩ ends. What shows is
/// the element's `clip-path: inset(top right bottom left)` in percent, written once the crop ends (`styles`).
enum CanvasCrop {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas, props = window.kelpProps; if (!K || !props) return;
          const layer = K.el('div', 'kelp-crop');
          layer.style.display = 'none';
          document.body.append(layer);
          let crop = null;   // { f, e, cut: [top, right, bottom, left] in 0…1, was }
          const sides = ['top', 'right', 'bottom', 'left'].map(side => {
            const h = K.el('div', 'kelp-crop-h kelp-crop-' + side); h.dataset.side = side; layer.append(h); return h;
          });
          const area = K.el('div', 'kelp-crop-area');
          const bar = K.el('div', 'kelp-crop-bar');
          layer.append(area, bar);
          const ratios = [[L.free, null], ['16:9', 16 / 9], ['1:1', 1], ['4:5', 4 / 5]];
          for (const [name, r] of ratios) {
            const b = K.el('button', 'kelp-ebtn', name);
            b.onclick = ev => { ev.stopPropagation(); if (r) aspect(r); };
            bar.append(b);
          }
          const reset = K.el('button', 'kelp-ebtn', L.reset);
          reset.onclick = ev => { ev.stopPropagation(); crop.cut = [0, 0, 0, 0]; show(); };
          bar.append(reset);
          const parse = e => {
            const m = (e.style.clipPath || '').match(/inset[(]([^)]*)[)]/);
            const n = m ? m[1].split(/ +/).map(v => parseFloat(v) / 100 || 0) : [];
            return [n[0] || 0, n[1] ?? n[0] ?? 0, n[2] ?? n[0] ?? 0, n[3] ?? n[1] ?? n[0] ?? 0];
          };
          const inset = c => 'inset(' + c.map(v => Math.round(v * 1000) / 10 + '%').join(' ') + ')';
          function show() {
            if (!crop) { layer.style.display = 'none'; return; }
            layer.style.display = 'block';
            crop.e.style.clipPath = inset(crop.cut);
            const b = K.box(crop.f, crop.e), [t, r, bo, l] = crop.cut;
            const v = { x: b.x + b.w * l, y: b.y + b.h * t, w: b.w * (1 - l - r), h: b.h * (1 - t - bo) };
            K.place(area, v);
            const spots = { top: [v.x + v.w / 2 - 12, v.y - 3], bottom: [v.x + v.w / 2 - 12, v.y + v.h - 3],
              left: [v.x - 3, v.y + v.h / 2 - 12], right: [v.x + v.w - 3, v.y + v.h / 2 - 12] };
            for (const h of sides) {
              const [x, y] = spots[h.dataset.side];
              Object.assign(h.style, { left: x + 'px', top: y + 'px' });
            }
            Object.assign(bar.style, { left: v.x + 'px', top: (v.y + v.h + 12) + 'px' });
          }
          // A shape at the middle of what shows now, as large as fits.
          function aspect(ratio) {
            const r = crop.e.getBoundingClientRect(), w = r.width, h = r.height;
            let vw = w, vh = w / ratio;
            if (vh > h) { vh = h; vw = h * ratio; }
            const x = (1 - vw / w) / 2, y = (1 - vh / h) / 2;
            crop.cut = [y, x, y, x];
            show();
          }
          function start(f, e) {
            if (crop) end(true);
            crop = { f, e, cut: parse(e), was: e.style.clipPath || '' };
            show();
          }
          function end(keep) {
            if (!crop) return;
            const c = crop; crop = null; show();
            if (!keep) { c.e.style.clipPath = c.was; return; }
            const now = c.cut.some(v => v > 0.001) ? inset(c.cut) : '';
            c.e.style.clipPath = now;
            if (now !== c.was) K.post({ kind: 'styles', board: c.f.dataset.board, id: K.need(c.f, c.e),
              props: { 'clip-path': now || null } });
          }
          window.kelpCrop = () => {
            const at = props.at();
            if (at && /^(IMG|VIDEO)$/.test(at.e.tagName)) start(at.f, at.e);
          };
          K.sheet.addEventListener('dblclick', ev => {
            const hit = K.mode() === 'edit' && K.under(ev, true);
            if (hit && /^(IMG|VIDEO)$/.test(hit.e.tagName)) start(hit.f, hit.e);
          });
          let drag = null;
          for (const h of sides) h.addEventListener('mousedown', ev => {
            ev.preventDefault(); ev.stopPropagation();
            drag = { side: h.dataset.side, x: ev.clientX, y: ev.clientY, cut: crop.cut.slice() };
          });
          area.addEventListener('mousedown', ev => {
            ev.preventDefault(); ev.stopPropagation();
            drag = { side: 'move', x: ev.clientX, y: ev.clientY, cut: crop.cut.slice() };
          });
          addEventListener('mousemove', ev => {
            if (!drag || !crop) return;
            const r = crop.e.getBoundingClientRect();
            const dx = (ev.clientX - drag.x) / r.width, dy = (ev.clientY - drag.y) / r.height;
            const [t, ri, b, l] = drag.cut, c = crop.cut, keep = 0.05;
            if (drag.side === 'top') c[0] = Math.min(Math.max(t + dy, 0), 1 - b - keep);
            if (drag.side === 'bottom') c[2] = Math.min(Math.max(b - dy, 0), 1 - t - keep);
            if (drag.side === 'left') c[3] = Math.min(Math.max(l + dx, 0), 1 - ri - keep);
            if (drag.side === 'right') c[1] = Math.min(Math.max(ri - dx, 0), 1 - l - keep);
            if (drag.side === 'move') {
              const mx = Math.min(Math.max(dx, -l), ri), my = Math.min(Math.max(dy, -t), b);
              crop.cut = [t + my, ri - mx, b - my, l + mx];
            }
            show();
          });
          addEventListener('mouseup', () => { drag = null; });
          addEventListener('keydown', ev => {
            if (!crop || (ev.key !== 'Escape' && ev.key !== 'Enter')) return;
            ev.preventDefault(); ev.stopPropagation();
            end(true);
          }, true);
          addEventListener('kelp-chosen', ev => { if (crop && (!ev.detail || ev.detail.e !== crop.e)) end(true); });
          addEventListener('kelp-zoom', () => { if (crop) show(); });
        """

    /// The crop's handles, its frame, and the bar of shapes under it.
    static let style = """
        .kelp-crop { position: absolute; inset: 0 auto auto 0; z-index: 18; pointer-events: none; }
        .kelp-crop-area { position: absolute; box-shadow: 0 0 0 1.5px var(--k-accent); cursor: move;
          pointer-events: auto; }
        .kelp-crop-h { position: absolute; width: 24px; height: 6px; border-radius: 3px; background: var(--k-accent);
          pointer-events: auto; }
        .kelp-crop-left, .kelp-crop-right { width: 6px; height: 24px; cursor: ew-resize; }
        .kelp-crop-top, .kelp-crop-bottom { cursor: ns-resize; }
        .kelp-crop-bar { position: absolute; display: flex; gap: 2px; padding: 3px; border-radius: 8px;
          background: var(--k-float); box-shadow: 0 2px 6px rgba(0,0,0,.2); font: 11px -apple-system, sans-serif;
          color: var(--k-label); pointer-events: auto; }
        """
}
