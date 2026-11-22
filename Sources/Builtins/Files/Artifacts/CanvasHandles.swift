import Foundation

/// The script for moving and sizing by hand in Edit, on a canvas's boards and a motion page's stage alike. It works
/// on the element `CanvasEditMode` chose (`kelp-chosen`):
/// - a drag on it moves it (its `translate`), snapping within 6 points to the board's edges and middle and to the
/// other elements' edges and middles, with red guides; Shift keeps to one axis, Option doesn't snap;
/// - its four corners size it: a box by its `width` and `height` (Shift keeps the proportions), a text by its `scale`
/// from the top left, so its lines don't break anew;
/// - the arrows move it a point, Shift ten;
/// - with an element chosen, pointing at another shows the distance between them in the board's points.
/// - ⌫ takes it out and ⌘D copies it (`remove`, `duplicate`); a right click asks for its menu (`menu`), and
/// `kelpArrange(front)` brings it in front of its siblings or sends it behind them.
/// An element whose own animation moves or sizes it isn't moved by hand: its tag says so. What changed goes to
/// `kelpSync` as `styles` (the board, the data-id and each property changed), once the drag ends.
enum CanvasHandles {
    static func source(animated: String) -> String {
        "(function (ANIMATED) {\n" + body + "\n})(\(MarkdownTab.js(animated)));"
    }

    private static let body = """
          const K = window.kelpCanvas; if (!K) return;
          const handles = K.el('div', 'kelp-handles'), guides = K.el('div', 'kelp-guides');
          document.body.append(handles, guides);
          const corners = ['nw', 'ne', 'sw', 'se'].map(c => {
            const h = K.el('div', 'kelp-handle kelp-h-' + c); h.dataset.c = c; handles.append(h); return h;
          });
          let at = null, drag = null, busy = false, nudged = null;
          const idOf = e => e.getAttribute('data-id');
          const css = e => e.ownerDocument.defaultView.getComputedStyle(e);
          const scaleOf = f => f.getBoundingClientRect().width / f.offsetWidth;
          const numbers = s => (s && s !== 'none' ? s.match(/-?[\\d.]+/g) || [] : []).map(Number);
          const moved = e => { const n = numbers(css(e).translate); return [n[0] || 0, n[1] || 0]; };
          const isText = e => !e.children.length && !!e.textContent.trim();
          const movesItself = e => e.getAnimations().some(a => (a.effect?.getKeyframes?.() || [])
            .some(k => 'translate' in k || 'scale' in k));
          function place() {
            const on = at && K.mode() === 'edit' && idOf(at.e);
            handles.style.display = on ? 'block' : 'none';
            if (!on) return;
            const b = K.box(at.f, at.e);
            const spots = { nw: [b.x, b.y], ne: [b.x + b.w, b.y], sw: [b.x, b.y + b.h], se: [b.x + b.w, b.y + b.h] };
            for (const h of corners) {
              const [x, y] = spots[h.dataset.c];
              Object.assign(h.style, { left: x - 4 + 'px', top: y - 4 + 'px' });
            }
          }
          addEventListener('kelp-chosen', ev => { at = ev.detail; place(); });
          addEventListener('kelp-zoom', place);
          addEventListener('resize', place);
          // The chosen element's tag says why it doesn't move, for a moment.
          function refuse() {
            const tag = document.querySelector('.kelp-tag'); if (!tag) return;
            const was = tag.textContent; tag.textContent = ANIMATED;
            setTimeout(() => { tag.textContent = was; }, 1800);
          }
          function start(ev, corner) {
            if (!at || !idOf(at.e)) return false;
            const e = at.e;
            if (movesItself(e)) { refuse(); return false; }
            const st = css(e), r = e.getBoundingClientRect(), was = {};
            for (const p of ['translate', 'width', 'height', 'scale', 'transform-origin'])
              was[p] = e.style.getPropertyValue(p);
            drag = { e, f: at.f, corner, x: ev.clientX, y: ev.clientY, k: scaleOf(at.f), t: moved(e), r, was,
              s: numbers(st.scale)[0] || 1, cw: parseFloat(st.width), ch: parseFloat(st.height), text: isText(e),
              moved: false };
            return true;
          }
          for (const h of corners) h.addEventListener('mousedown', ev => {
            if (start(ev, h.dataset.c)) { ev.preventDefault(); ev.stopPropagation(); }
          });
          K.sheet.addEventListener('mousedown', ev => {
            if (K.mode() !== 'edit' || !at) return;
            const hit = K.under(ev, true);
            if (hit && hit.f === at.f && at.e.contains(hit.e) && start(ev, null)) ev.preventDefault();
          });
          // The board's edges and middle, and the other elements' edges and middles, in the board's points.
          function snap(dx, dy) {
            guides.replaceChildren();
            const d = drag, doc = d.e.ownerDocument, near = 6 / d.k, r = d.r;
            const W = doc.documentElement.clientWidth, H = doc.documentElement.clientHeight;
            const xs = [0, W / 2, W], ys = [0, H / 2, H];
            for (const o of doc.querySelectorAll('[data-id]')) {
              if (o.contains(d.e) || d.e.contains(o) || css(o).visibility === 'hidden') continue;
              const q = o.getBoundingClientRect(); if (!q.width) continue;
              xs.push(q.left, q.left + q.width / 2, q.right); ys.push(q.top, q.top + q.height / 2, q.bottom);
            }
            const best = (mine, theirs) => {
              let b = null;
              for (const m of mine) for (const t of theirs) {
                const g = t - m;
                if (Math.abs(g) < near && (!b || Math.abs(g) < Math.abs(b.g))) b = { g, t };
              }
              return b;
            };
            const bx = best([r.left, r.left + r.width / 2, r.right].map(v => v + dx), xs);
            const by = best([r.top, r.top + r.height / 2, r.bottom].map(v => v + dy), ys);
            if (bx) { dx += bx.g; line(bx.t, null); }
            if (by) { dy += by.g; line(null, by.t); }
            return [dx, dy];
          }
          function line(x, y) {
            const fr = drag.f.getBoundingClientRect(), k = drag.k, g = K.el('div', 'kelp-guide');
            const left = fr.left + scrollX, top = fr.top + scrollY;
            Object.assign(g.style, x !== null
              ? { left: left + x * k + 'px', top: top + 'px', width: '1px', height: fr.height + 'px' }
              : { left: left + 'px', top: top + y * k + 'px', width: fr.width + 'px', height: '1px' });
            guides.append(g);
          }
          addEventListener('mousemove', ev => {
            if (!drag) return;
            let dx = (ev.clientX - drag.x) / drag.k, dy = (ev.clientY - drag.y) / drag.k;
            if (!drag.moved && Math.hypot(dx, dy) * drag.k < 4) return;
            drag.moved = busy = true;
            const e = drag.e;
            if (!drag.corner) {
              if (ev.shiftKey) { if (Math.abs(dx) > Math.abs(dy)) dy = 0; else dx = 0; }
              if (!ev.altKey) [dx, dy] = snap(dx, dy);
              e.style.translate = Math.round(drag.t[0] + dx) + 'px ' + Math.round(drag.t[1] + dy) + 'px';
            } else {
              const left = drag.corner[1] === 'w', top = drag.corner[0] === 'n', r = drag.r;
              const w = Math.max(8, r.width + (left ? -dx : dx));
              const h = ev.shiftKey || drag.text ? r.height * w / r.width : Math.max(8, r.height + (top ? -dy : dy));
              if (drag.text) {
                e.style.transformOrigin = '0 0';
                e.style.scale = +(drag.s * w / r.width).toFixed(3);
              } else {
                e.style.width = Math.round(drag.cw + w - r.width) + 'px';
                e.style.height = Math.round(drag.ch + h - r.height) + 'px';
              }
              const tx = drag.t[0] + (left ? r.width - w : 0), ty = drag.t[1] + (top ? r.height - h : 0);
              e.style.translate = Math.round(tx) + 'px ' + Math.round(ty) + 'px';
            }
            window.kelpOutline?.(); place();
          });
          function save(e, f, was) {
            const props = {};
            for (const p of Object.keys(was)) {
              const v = e.style.getPropertyValue(p);
              if (v !== was[p]) props[p] = v || null;
            }
            if (Object.keys(props).length) K.post({ kind: 'styles', board: f.dataset.board, id: idOf(e), props });
          }
          addEventListener('mouseup', () => {
            if (!drag) return;
            const d = drag; drag = null; guides.replaceChildren();
            setTimeout(() => { busy = false; });
            if (d.moved) save(d.e, d.f, d.was);
          });
          // The arrows move the chosen element; it is written once they rest.
          addEventListener('keydown', ev => {
            const t = ev.target;
            if (K.mode() !== 'edit' || !at || !idOf(at.e) || !ev.key.startsWith('Arrow') || ev.metaKey) return;
            if (t.isContentEditable || /^(INPUT|TEXTAREA)$/.test(t.tagName)) return;
            ev.preventDefault();
            if (movesItself(at.e)) return refuse();
            const n = ev.shiftKey ? 10 : 1, [x, y] = moved(at.e);
            const v = { ArrowLeft: [-n, 0], ArrowRight: [n, 0], ArrowUp: [0, -n], ArrowDown: [0, n] }[ev.key];
            if (!nudged) nudged = { e: at.e, f: at.f, was: { translate: at.e.style.getPropertyValue('translate') } };
            at.e.style.translate = (x + v[0]) + 'px ' + (y + v[1]) + 'px';
            window.kelpOutline?.(); place();
            clearTimeout(nudged.timer);
            nudged.timer = setTimeout(() => { const d = nudged; nudged = null; save(d.e, d.f, d.was); }, 500);
          });
          // With an element chosen, the distance to the one pointed at: a line and its length for each side apart.
          K.sheet.addEventListener('mousemove', ev => {
            if (drag) return;
            for (const m of document.querySelectorAll('.kelp-measure')) m.remove();
            const hit = K.mode() === 'edit' && at && K.under(ev, true);
            if (!hit || hit.f !== at.f || hit.e.contains(at.e) || at.e.contains(hit.e)) return;
            const a = at.e.getBoundingClientRect(), b = hit.e.getBoundingClientRect();
            const midY = (Math.max(a.top, b.top) + Math.min(a.bottom, b.bottom)) / 2;
            const midX = (Math.max(a.left, b.left) + Math.min(a.right, b.right)) / 2;
            const y = a.bottom > b.top && b.bottom > a.top ? midY : a.top + a.height / 2;
            const x = a.right > b.left && b.right > a.left ? midX : a.left + a.width / 2;
            if (b.left >= a.right) measure(a.right, y, b.left, y);
            if (a.left >= b.right) measure(b.right, y, a.left, y);
            if (b.top >= a.bottom) measure(x, a.bottom, x, b.top);
            if (a.top >= b.bottom) measure(x, b.bottom, x, a.top);
          });
          function measure(x0, y0, x1, y1) {
            const fr = at.f.getBoundingClientRect(), k = scaleOf(at.f);
            const left = fr.left + scrollX, top = fr.top + scrollY;
            const g = K.el('div', 'kelp-guide kelp-measure'), n = K.el('div', 'kelp-measure kelp-measure-n');
            Object.assign(g.style, {
              left: left + x0 * k + 'px', top: top + y0 * k + 'px',
              width: Math.max(1, (x1 - x0) * k) + 'px', height: Math.max(1, (y1 - y0) * k) + 'px'
            });
            n.textContent = Math.round(Math.max(x1 - x0, y1 - y0));
            Object.assign(n.style, { left: left + (x0 + x1) / 2 * k + 'px', top: top + (y0 + y1) / 2 * k + 'px' });
            guides.append(g, n);
          }
          // ⌫ takes the chosen element out, ⌘D copies it; a right click chooses an element and asks for its menu.
          addEventListener('keydown', ev => {
            const t = ev.target;
            if (K.mode() !== 'edit' || !at || !idOf(at.e)) return;
            if (t.isContentEditable || /^(INPUT|TEXTAREA)$/.test(t.tagName)) return;
            const kind = ev.key === 'Backspace' || ev.key === 'Delete' ? 'remove'
              : ev.metaKey && ev.key.toLowerCase() === 'd' ? 'duplicate' : null;
            if (!kind) return;
            ev.preventDefault();
            K.post({ kind, board: at.f.dataset.board, id: idOf(at.e) });
          });
          K.sheet.addEventListener('contextmenu', ev => {
            if (K.mode() !== 'edit') return;
            const hit = K.under(ev, false), id = hit && idOf(hit.e);
            if (!id) return;
            ev.preventDefault();
            window.kelpSelect?.(hit.f.dataset.board, id);
            K.post({ kind: 'selected', board: hit.f.dataset.board, id });
            K.post({ kind: 'menu', board: hit.f.dataset.board, id, image: hit.e.tagName === 'IMG' });
          });
          // Brings the chosen element in front of the others beside it, or sends it behind them.
          window.kelpArrange = front => {
            if (!at || !idOf(at.e)) return;
            const e = at.e, zs = [...(e.parentElement?.children || [])].filter(o => o !== e)
              .map(o => parseInt(css(o).zIndex) || 0);
            const z = front ? Math.max(0, ...zs) + 1 : Math.min(0, ...zs) - 1, props = { 'z-index': String(z) };
            if (css(e).position === 'static') props.position = 'relative';
            for (const [p, v] of Object.entries(props)) e.style.setProperty(p, v);
            K.post({ kind: 'styles', board: at.f.dataset.board, id: idOf(e), props });
          };
          // What is at a point of the page (a drop): the board, the image there with its data-id, and the point in
          // the board's own points.
          window.kelpPointAt = (x, y) => {
            const hit = K.under({ clientX: x, clientY: y }, true); if (!hit) return null;
            const fr = hit.f.getBoundingClientRect(), k = scaleOf(hit.f), img = hit.e.closest('img');
            return { board: hit.f.dataset.board, image: !!img, id: img ? idOf(img) || '' : '',
              x: (x - fr.left) / k, y: (y - fr.top) / k };
          };
          window.kelpHandles = { busy: () => busy };
        """

    /// The CSS for the corners, the guides and the distances.
    static let style = """
        .kelp-handles { position: absolute; inset: 0 auto auto 0; display: none; z-index: 16; pointer-events: none; }
        .kelp-handle { position: absolute; width: 8px; height: 8px; box-sizing: border-box; background: #fff;
          border: 1.5px solid var(--k-accent); border-radius: 2px; pointer-events: auto; }
        .kelp-h-nw, .kelp-h-se { cursor: nwse-resize; }
        .kelp-h-ne, .kelp-h-sw { cursor: nesw-resize; }
        .kelp-guides { position: absolute; inset: 0 auto auto 0; z-index: 16; pointer-events: none; }
        .kelp-guide { position: absolute; background: #ff2d55; }
        .kelp-measure-n { position: absolute; transform: translate(-50%, -50%); padding: 0 4px; border-radius: 3px;
          background: #ff2d55; color: #fff; font: 600 10px/15px -apple-system, sans-serif; }
        """
}
