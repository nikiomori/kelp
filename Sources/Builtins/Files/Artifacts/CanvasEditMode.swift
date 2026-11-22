import Foundation

/// The script for Edit on a canvas or a motion page's stage, where the user changes a board by hand without the agent
/// (`kelpEdit(true)` from the bar). It works on top of the sheet from `CanvasEdit`. A click chooses an element and
/// outlines it; the column is then its inspector: the element's name and the way up to its parent, and a row a
/// property, by section (Text, Layout, Position, Fill, and Time on a motion page). A row shows the value as it is now
/// (a token's name, the page's own value) and opens the Mac's menu of choices, the design system's tokens first and
/// the values the page already uses after (`propMenu`, answered by `kelpProps.set`); numbers are fields, opacity a
/// slider; ↺ shows on a row changed by hand and takes it back to the page's own. A double click on an element that
/// holds only text lets the user type over it (Enter keeps, Esc drops). It sends `selected` (to choose the element
/// again once the canvas is drawn again), `style`, `styles`, `text` and `retimeElement`, which the tab writes into the
/// board's file by the element's data-id (`BoardEdit`). `window.kelpProps` is what the floating bar (`CanvasEditBar`)
/// shares.
enum CanvasEditMode {
    /// The words the column shows, by key: title, noID, giveID, choose, text, layout, position, fill, time, size,
    /// weight, colour, padding, gap, background, radius, opacity, offset, frame, startLength, none, auto, regular,
    /// medium, semibold, bold, reset, seconds.
    typealias Labels = [String: String]

    static func source(tokens: [String: [String]], labels: Labels) -> String {
        let groups = Dictionary(
            uniqueKeysWithValues: ["color", "size", "space", "radius"].map { ($0, tokens[$0] ?? []) })
        return """
            (function () {
              const K = window.kelpCanvas, C = window.kelpColumn; if (!K || !C) return;
              const T = \(MarkdownTab.js(groups));
              const L = \(MarkdownTab.js(labels));
            \(choices)
            \(body)
            })();
            """
    }

    /// The properties and their choices: `P` by key, what a value is now (`shown`), and what can be chosen (`menu`),
    /// as the rows and the bar show them.
    private static let choices = """
          const idOf = e => e.getAttribute('data-id');
          const css = e => e.ownerDocument.defaultView.getComputedStyle(e);
          const P = {
            size: { prop: 'font-size', group: 'size' }, weight: { prop: 'font-weight' },
            colour: { prop: 'color', group: 'color' }, padding: { prop: 'padding', group: 'space' },
            gap: { prop: 'gap', group: 'space' }, background: { prop: 'background', group: 'color', none: true },
            radius: { prop: 'border-radius', group: 'radius' }, opacity: { prop: 'opacity' }
          };
          const weights = [['400', L.regular], ['500', L.medium], ['600', L.semibold], ['700', L.bold]];
          const tokenName = (group, n) => '--' + (group === 'color' ? n : group + '-' + n);
          const tokenValue = (e, group, n) => css(e.ownerDocument.documentElement)
            .getPropertyValue(tokenName(group, n)).trim();
          function hex(c) {
            const m = String(c).match(/rgba?[(]([^)]*)[)]/); if (!m) return String(c);
            const p = m[1].split(',').map(s => parseFloat(s));
            if (p.length > 3 && p[3] === 0) return 'none';
            return '#' + p.slice(0, 3).map(n => Math.round(n).toString(16).padStart(2, '0')).join('');
          }
          const px = v => String(Math.round(parseFloat(v) || 0));
          // The page's own values, after the tokens: the colours and text sizes its elements use.
          function own(doc, group) {
            if (!['color', 'size'].includes(group)) return [];
            const seen = new Set();
            for (const x of doc.body.querySelectorAll('*')) {
              const st = css(x);
              if (group === 'size') seen.add(px(st.fontSize));
              else for (const c of [st.color, st.backgroundColor]) { const h = hex(c); if (h !== 'none') seen.add(h); }
            }
            const list = [...seen].slice(0, 12);
            if (group === 'size') list.sort((a, b) => a - b);
            return list.map(v => group === 'size' ? { value: v + 'px', title: v + ' px' }
              : { value: v, title: v, swatch: v });
          }
          // What the property is now: its title, a detail, a swatch, and whether it was changed by hand (`set`).
          function shown(key, e) {
            const p = P[key], set = e.style.getPropertyValue(p.prop).trim(), st = css(e);
            const token = set.match(/^var[(]--(.+)[)]$/);
            const name = token ? token[1].replace(p.group === 'color' ? '' : p.group + '-', '') : null;
            if (key === 'weight') {
              const w = weights.find(([v]) => v === String(Math.round(parseFloat(st.fontWeight) / 100) * 100));
              return { title: w ? w[1] : st.fontWeight, detail: st.fontWeight, set: !!set };
            }
            if (key === 'opacity') return { title: Math.round(parseFloat(st.opacity) * 100) + ' %', set: !!set };
            if (p.group === 'color') {
              const v = hex(key === 'background' ? st.backgroundColor : st.color);
              return { title: name || (v === 'none' ? L.none : v), swatch: v === 'none' ? null : v, set: !!set };
            }
            const v = key === 'size' ? px(st.fontSize) : px(st.getPropertyValue(p.prop));
            return { title: name || v, detail: name ? v : null, set: !!set };
          }
          // The choices for `key` on element `e`: the tokens first, then the page's own values.
          function menu(key, e) {
            const p = P[key], now = e.style.getPropertyValue(p.prop).trim(), out = [];
            if (key === 'weight') return weights.map(([v, t]) => ({ value: v, title: t, detail: v, on: now === v }));
            if (key === 'opacity')
              return [1, 0.75, 0.5, 0.25].map(v => ({ value: String(v), title: v * 100 + ' %',
                on: now === String(v) }));
            if (p.none) out.push({ value: 'none', title: L.none, section: 'tokens', on: now === 'none' });
            for (const n of T[p.group] || []) {
              const value = 'var(' + tokenName(p.group, n) + ')', v = tokenValue(e, p.group, n);
              const colour = p.group === 'color';
              out.push({ value, title: n, detail: colour ? null : v, swatch: colour ? v : null, section: 'tokens',
                on: now === value });
            }
            for (const o of own(e.ownerDocument, p.group))
              out.push(Object.assign({ section: 'page', on: now === o.value }, o));
            return out;
          }
          window.kelpProps = {
            P, shown, menu, at: () => null,
            // Asks the Mac for the menu of `key`'s choices, at the pointer; the choice comes back to `set`.
            open(key) {
              const at = window.kelpProps.at(); if (!at) return;
              K.post({ kind: 'propMenu', key, items: menu(key, at.e), reset: shown(key, at.e).set });
            }
          };
        """

    private static let body = """
          const chosen = K.el('div', 'kelp-chosen'), tag = K.el('div', 'kelp-tag');
          K.layer.append(chosen, tag);
          let at = null;
          window.kelpProps.at = () => at;
          const nameOf = e => e.tagName.toLowerCase() + (idOf(e) ? ' · ' + idOf(e) : '');
          const titleOf = e => e.dataset.title || (e.children.length ? '' : (e.textContent || '').trim().slice(0, 32))
            || nameOf(e);
          window.kelpEdit = on => {
            K.setMode(on ? 'edit' : K.mode() === 'edit' ? null : K.mode());
            if (on) choose(at, true); else { choose(null, true); if (K.mode() !== 'mark') C.close(); }
          };
          function outline() {
            if (!at) return;
            const b = K.box(at.f, at.e);
            K.place(chosen, b);
            Object.assign(tag.style, { left: b.x + 'px', top: (b.y - 20) + 'px' });
          }
          window.kelpOutline = outline;
          function draw() {
            if (K.mode() !== 'edit') return;
            if (!at) return C.open([K.el('span', 'kelp-grow', L.title)], [K.el('p', 'kelp-note', L.choose)]);
            C.open([K.el('span', 'kelp-grow', titleOf(at.e))], inspector());
          }
          function choose(next, quiet) {
            at = next;
            dispatchEvent(new CustomEvent('kelp-chosen', { detail: K.mode() === 'edit' ? at : null }));
            chosen.style.display = tag.style.display = at ? 'block' : 'none';
            const which = at ? { board: at.f.dataset.board, id: idOf(at.e) } : {};
            if (!quiet) K.post(Object.assign({ kind: 'selected' }, which));
            if (K.mode() !== 'edit') return;
            if (at) { tag.textContent = nameOf(at.e); outline(); }
            draw();
          }
          window.kelpSelect = (board, id) => {
            const f = K.light(board), e = f && f.contentDocument
              && f.contentDocument.querySelector('[data-id="' + CSS.escape(id) + '"]');
            if (e) choose({ f, e }, true);
          };
          addEventListener('kelp-zoom', outline);
          const changed = () => { outline(); draw(); dispatchEvent(new CustomEvent('kelp-props')); };
          // A value chosen in a menu, a field or the slider: shown at once, written to the file.
          function set(key, value) {
            if (!at) return;
            const p = P[key] || { prop: key }, e = at.e;
            if (value) e.style.setProperty(p.prop, value); else e.style.removeProperty(p.prop);
            K.post({ kind: 'style', board: at.f.dataset.board, id: idOf(e), property: p.prop, value: value || null });
            changed();
          }
          window.kelpProps.set = set;
          function styles(props) {
            if (!at) return;
            for (const [k, v] of Object.entries(props)) {
              if (v) at.e.style.setProperty(k, v); else at.e.style.removeProperty(k);
            }
            K.post({ kind: 'styles', board: at.f.dataset.board, id: idOf(at.e), props });
            changed();
          }
          // One row: its name, what it is now, ↺ while it's changed by hand.
          function row(label, control, wasSet, reset) {
            const r = K.el('div', 'kelp-irow'), back = K.el('button', 'kelp-ireset');
            if (wasSet) {
              back.append(K.el('span', 'kelp-sym-arrow-uturn-backward'));
              back.title = L.reset; back.onclick = reset;
            }
            r.append(K.el('span', 'kelp-ilabel', label), control, back);
            return r;
          }
          function popup(key) {
            const s = shown(key, at.e), b = K.el('button', 'kelp-ipop'), name = K.el('span', 'kelp-itok');
            if (s.swatch) { const w = K.el('span', 'kelp-iswatch'); w.style.background = s.swatch; name.append(w); }
            name.append(s.title);
            b.append(name, K.el('span', 'kelp-ival', s.detail || ''));
            b.onclick = () => window.kelpProps.open(key);
            return row(L[key], b, s.set, () => set(key, null));
          }
          function field(prefix, value, done) {
            const box = K.el('label', 'kelp-ifld'), input = K.el('input');
            input.value = value;
            input.addEventListener('keydown', ev => { if (ev.key === 'Enter') input.blur(); ev.stopPropagation(); });
            input.addEventListener('change', () => done(input.value.trim()));
            if (prefix) box.append(K.el('b', null, prefix));
            box.append(input);
            return box;
          }
          function pair(a, b) { const p = K.el('span', 'kelp-ipair'); p.append(a, b); return p; }
          function section(title, rows) {
            const s = K.el('div', 'kelp-isec');
            s.append(K.el('div', 'kelp-ititle', title), ...rows);
            return s;
          }
          // Where a motion page's element is in time: its own (a scene, a picture) or its animation's.
          function timing(e) {
            if (e.dataset.start != null) return [+e.dataset.start || 0, +e.dataset.duration || 0];
            const a = e.getAnimations()[0], t = a && a.effect && a.effect.getComputedTiming();
            return t ? [(t.delay || 0) / 1000, (t.activeDuration || 0) / 1000] : null;
          }
          const has = key => !P[key].group || (T[P[key].group] || []).length
            || ['color', 'size'].includes(P[key].group);
          function position(e) {
            const st = css(e), moved = (st.translate.match(/-?[0-9.]+/g) || ['0', '0']).map(Number);
            const x = moved[0] || 0, y = moved[1] || 0, r = e.getBoundingClientRect();
            const shift = (nx, ny) => styles({ translate: Math.round(nx) + 'px ' + Math.round(ny) + 'px' });
            return section(L.position, [
              row(L.offset, pair(field('X', px(x), v => shift(+v || 0, y)), field('Y', px(y), v => shift(x, +v || 0))),
                !!e.style.translate, () => styles({ translate: null })),
              row(L.frame, pair(field('W', px(r.width), v => styles({ width: +v ? v + 'px' : null })),
                field('H', e.style.height ? px(r.height) : L.auto, v => styles({ height: +v ? v + 'px' : null }))),
                !!(e.style.width || e.style.height), () => styles({ width: null, height: null }))
            ]);
          }
          function fill(e) {
            const slider = K.el('span', 'kelp-islide'), range = K.el('input'), pct = K.el('span', 'kelp-ival');
            range.type = 'range'; range.min = 0; range.max = 100;
            range.value = Math.round(parseFloat(css(e).opacity) * 100);
            pct.textContent = range.value + ' %';
            range.oninput = () => { pct.textContent = range.value + ' %'; e.style.opacity = range.value / 100; };
            range.onchange = () => set('opacity', String(range.value / 100));
            slider.append(range, pct);
            const rows = ['background', 'radius'].filter(has).map(popup);
            rows.push(row(L.opacity, slider, !!e.style.opacity, () => set('opacity', null)));
            return section(L.fill, rows);
          }
          function time(e, id) {
            const when = timing(e), send = (start, length) => K.post({ kind: 'retimeElement', id, start, length });
            const sec = v => (Math.round(v * 100) / 100) + ' ' + L.seconds, num = v => parseFloat(v.replace(',', '.'));
            return section(L.time, [row(L.startLength, pair(
              field('', sec(when[0]), v => send(num(v) || 0, when[1])),
              field('', sec(when[1]), v => send(when[0], num(v) || when[1]))), false)]);
          }
          function inspector() {
            const e = at.e, id = idOf(e), out = [];
            const head = K.el('div', 'kelp-ihead'), crumb = K.el('div', 'kelp-icrumb'), p = e.parentElement;
            if (p && p !== e.ownerDocument.body) {
              const up = K.el('button', 'kelp-ilink', titleOf(p));
              up.onclick = () => choose({ f: at.f, e: p });
              crumb.append(up, ' › ');
            }
            crumb.append(nameOf(e));
            head.append(crumb);
            out.push(head);
            if (!id) {
              // Found again by its place among the body's elements of its tag, to write a data-id into its file.
              const give = K.el('button', 'kelp-pill', L.giveID), doc = e.ownerDocument;
              give.onclick = () => K.post({ kind: 'giveID', board: at.f.dataset.board, tag: e.tagName.toLowerCase(),
                index: [...doc.body.getElementsByTagName(e.tagName)].indexOf(e) });
              const r = K.el('div', 'kelp-row kelp-end');
              r.append(give);
              return [...out, K.el('p', 'kelp-note', L.noID), r];
            }
            const text = !e.children.length && e.textContent.trim();
            if (text) out.push(section(L.text, ['size', 'weight', 'colour'].map(popup)));
            const layout = ['padding', 'gap'].filter(key => (T[P[key].group] || []).length);
            if (layout.length) out.push(section(L.layout, layout.map(popup)));
            out.push(position(e), fill(e));
            if (window.kelpMotion && timing(e)) out.push(time(e, id));
            return out;
          }
          K.sheet.addEventListener('click', ev => {
            if (K.mode() === 'edit' && !window.kelpHandles?.busy()) choose(K.under(ev, true));
          });
          K.sheet.addEventListener('dblclick', ev => {
            const hit = K.mode() === 'edit' && K.under(ev, true);
            if (hit && !hit.e.children.length && hit.e.textContent.trim()) typeOver(hit);
          });
          // A field of the page's own over the element: the board's frame runs no script, so typing in it is unheard.
          function typeOver(hit) {
            const e = hit.e, look = css(e), b = K.box(hit.f, e);
            const k = b.w / (e.getBoundingClientRect().width || 1), old = e.textContent.trim();
            const input = K.el('textarea', 'kelp-type');
            input.value = old;
            Object.assign(input.style, {
              left: b.x + 'px', top: b.y + 'px', width: Math.max(b.w, 60) + 'px', height: Math.max(b.h, 20) + 'px',
              fontFamily: look.fontFamily, fontWeight: look.fontWeight, fontSize: parseFloat(look.fontSize) * k + 'px',
              lineHeight: (parseFloat(look.lineHeight) || parseFloat(look.fontSize) * 1.3) * k + 'px',
              color: look.color, textAlign: look.textAlign, letterSpacing: look.letterSpacing
            });
            document.body.append(input);
            e.style.visibility = 'hidden';
            input.focus();
            input.select();
            const done = keep => {
              if (!input.isConnected) return;
              input.remove();
              e.style.visibility = '';
              if (keep && input.value.trim() && input.value !== old) {
                e.textContent = input.value;
                K.post({ kind: 'text', board: hit.f.dataset.board, id: idOf(e), old, text: input.value });
              }
              outline();
            };
            input.addEventListener('keydown', ev => {
              if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); done(true); }
              if (ev.key === 'Escape') { ev.preventDefault(); done(false); }
            });
            input.addEventListener('blur', () => done(true));
          }
        """

    /// The CSS for the chosen element's outline and name tag, the inspector's rows, and the field the user types over
    /// an element.
    static let style = """
        .kelp-chosen { position: absolute; display: none; border: 2px solid var(--k-accent); border-radius: 3px; }
        .kelp-tag { position: absolute; display: none; height: 16px; padding: 0 5px; border-radius: 4px;
          background: var(--k-accent); color: #fff; font: 500 10px/16px -apple-system, sans-serif;
          white-space: nowrap; }
        .kelp-q { color: var(--k-sec); }
        .kelp-ihead { padding: 0 12px 8px; border-bottom: 1px solid var(--k-sep); }
        .kelp-icrumb { color: var(--k-sec); font-size: 11px; }
        .kelp-ilink { border: 0; background: none; color: var(--k-sec); font: inherit; padding: 0 2px;
          border-radius: 4px; }
        .kelp-ilink:hover { background: var(--k-hover); color: var(--k-label); }
        .kelp-isec { padding: 8px 12px 6px; border-bottom: 1px solid var(--k-sep); }
        .kelp-ititle { font-size: 11px; font-weight: 600; color: var(--k-sec); margin-bottom: 4px; }
        .kelp-irow { display: grid; grid-template-columns: 88px minmax(0, 1fr) 16px; align-items: center; gap: 6px;
          height: 26px; }
        .kelp-ilabel { color: var(--k-sec); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .kelp-ireset { border: 0; background: none; color: var(--k-sec); padding: 0; font-size: 11px;
          border-radius: 4px; }
        .kelp-ireset:hover { color: var(--k-label); background: var(--k-hover); }
        .kelp-ipop { display: flex; align-items: center; height: 20px; min-width: 0; padding: 0 6px; border: 0;
          border-radius: 5px; background: var(--k-hover); color: var(--k-label); font: 12px -apple-system, sans-serif; }
        .kelp-ipop:hover { background: var(--k-sel); }
        .kelp-ipop::after { content: "⌄"; color: var(--k-sec); font-size: 10px; margin-left: 4px; position: relative;
          top: -2px; }
        .kelp-itok { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .kelp-ival { color: var(--k-sec); margin-left: auto; padding-left: 6px; font-variant-numeric: tabular-nums; }
        .kelp-iswatch { display: inline-block; width: 12px; height: 12px; border-radius: 3px; margin-right: 6px;
          vertical-align: -2px; box-shadow: inset 0 0 0 1px var(--k-sep); }
        .kelp-ipair { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }
        .kelp-ifld { display: flex; align-items: center; height: 20px; padding: 0 6px; border-radius: 5px;
          background: var(--k-card); box-shadow: inset 0 0 0 1px var(--k-sep); }
        .kelp-ifld b { color: var(--k-quiet); font-weight: 500; font-size: 10px; margin-right: 6px; }
        .kelp-ifld input { width: 100%; min-width: 0; border: 0; outline: 0; background: none; color: var(--k-label);
          font: 12px -apple-system, sans-serif; font-variant-numeric: tabular-nums; padding: 0; }
        .kelp-ifld:focus-within { box-shadow: 0 0 0 2px var(--k-accent); }
        .kelp-islide { display: flex; align-items: center; gap: 8px; }
        .kelp-islide input { flex: 1; min-width: 0; accent-color: var(--k-sec); }
        .kelp-type { position: absolute; z-index: 26; margin: 0; padding: 0; border: 0; resize: none;
          overflow: hidden; background: rgba(0,122,255,.08); outline: 2px solid var(--k-accent); border-radius: 2px; }
        """
}
