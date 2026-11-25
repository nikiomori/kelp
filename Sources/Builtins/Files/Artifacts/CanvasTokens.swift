import Foundation

/// The nearest token, offered where a value isn't one (Open Design's Reference values). A finding of Check's that a
/// colour, a text size or a radius isn't a token gets Use <token> (the element it names) and All N (every element
/// with that value on the boards, by data-id), sent as `useToken` and written by hand. An Edit menu of a colour, a
/// size, a space or a radius whose value isn't a token puts the closest one first, marked ≈.
enum CanvasTokens {
    /// A finding of Check's about a value that isn't a token (`CanvasScript`'s words): its board, what (colour, size,
    /// radius), the value, the element's data-id and the nearest token's name.
    static let finding =
        #"^(.+?)(?: \(dark\))?: (colour|size|radius) (#[0-9a-f]{6}|[0-9]+px) in \[data-id=([^\]]+)\] "#
        + #"is not a token \(nearest: (\S+) "#

    static func source(labels: [String: String]) -> String {
        "(function (L, FINDING) {\n" + body + "\n})(\(MarkdownTab.js(labels)), \(MarkdownTab.js(finding)));"
    }

    private static let body = """
          const K = window.kelpCanvas, props = window.kelpProps; if (!K || !props) return;
          const probe = document.createElement('i');
          // A CSS colour as [r, g, b], read by the page itself.
          function rgbOf(c) {
            probe.style.color = ''; probe.style.color = c; document.body.append(probe);
            const m = getComputedStyle(probe).color.match(/[0-9.]+/g); probe.remove();
            return m ? m.slice(0, 3).map(Number) : null;
          }
          const hex = c => { const v = rgbOf(c); return v ? '#' + v.map(n => Math.round(n).toString(16)
            .padStart(2, '0')).join('') : ''; };
          const own = e => [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
          // What a finding's value is on an element: the property it sits in, or null.
          function holds(e, kind, value) {
            const st = e.ownerDocument.defaultView.getComputedStyle(e);
            if (kind === 'colour') {
              if (own(e) && hex(st.color) === value) return 'color';
              return hex(st.backgroundColor) === value ? 'background' : null;
            }
            const px = v => Math.round(parseFloat(v)) + 'px';
            if (kind === 'size') return own(e) && px(st.fontSize) === value ? 'font-size' : null;
            return px(st.borderTopLeftRadius) === value ? 'border-radius' : null;
          }
          const finding = new RegExp(FINDING);
          window.kelpIssueFix = (line, row) => {
            const m = line.match(finding); if (!m) return;
            const [, board, kind, value, id, name] = m;
            const token = 'var(--' + (kind === 'colour' ? '' : kind + '-') + name + ')';
            // Every element with this value, by board: those with a data-id, so it can be written.
            const all = new Map();
            for (const f of K.frames) {
              if (f.dataset.theme === 'dark' || !f.contentDocument) continue;
              for (const e of f.contentDocument.querySelectorAll('[data-id]')) {
                const property = holds(e, kind, value);
                if (!property) continue;
                if (!all.has(f.dataset.board)) all.set(f.dataset.board, []);
                all.get(f.dataset.board).push({ id: e.getAttribute('data-id'), property });
              }
            }
            const mine = (all.get(board) || []).find(c => c.id === id);
            const count = [...all.values()].reduce((n, l) => n + l.length, 0);
            if (!mine) return;
            const send = list => {
              for (const [b, changes] of list) K.post({ kind: 'useToken', board: b, changes, value: token });
            };
            const fix = K.el('div', 'kelp-ifix'), use = K.el('button', 'kelp-pill', L.use.replace('%@', name));
            use.onclick = () => send([[board, [mine]]]);
            fix.append(use);
            if (count > 1) {
              const every = K.el('button', 'kelp-pill', L.allOf.replace('%d', count));
              every.onclick = () => send([...all]);
              fix.append(every);
            }
            row.append(fix);
          };
          // The closest token to what `key` is now on `e`, when it isn't a token: first in its menu, marked ≈.
          function nearest(key, e, items) {
            const p = props.P[key]; if (!p || !p.group) return items;
            const now = e.style.getPropertyValue(p.prop).trim();
            if (/^var[(]--/.test(now)) return items;
            const tokens = items.filter(i => i.section === 'tokens' && i.value !== 'none');
            const st = e.ownerDocument.defaultView.getComputedStyle(e);
            let best = null;
            if (p.group === 'color') {
              const c = rgbOf(key === 'background' ? st.backgroundColor : st.color); if (!c) return items;
              for (const t of tokens) {
                const v = rgbOf(t.swatch || ''); if (!v) continue;
                const d = Math.hypot(v[0] - c[0], v[1] - c[1], v[2] - c[2]);
                if (d < 60 && (!best || d < best.d)) best = { t, d };
              }
            } else {
              const v = parseFloat(key === 'size' ? st.fontSize : st.getPropertyValue(p.prop));
              for (const t of tokens) {
                const d = Math.abs(parseFloat(t.detail) - v);
                if (d <= 8 && (!best || d < best.d)) best = { t, d };
              }
            }
            if (!best) return items;
            return [Object.assign({}, best.t, { title: '≈ ' + best.t.title, section: 'nearest', on: false }), ...items];
          }
          props.open = key => {
            const at = props.at(); if (!at) return;
            K.post({ kind: 'propMenu', key, items: nearest(key, at.e, props.menu(key, at.e)),
              reset: props.shown(key, at.e).set, board: at.f.dataset.board, id: at.e.getAttribute('data-id') });
          };
        """

    static let style = """
        .kelp-issue:has(.kelp-ifix) { flex-wrap: wrap; }
        .kelp-ifix { flex-basis: 100%; display: flex; gap: 6px; padding: 4px 0 0 18px; }
        """
}
