import Foundation

/// Edit on a canvas, by hand, without the agent (`kelpEdit(true)` from the bar), on top of `CanvasEdit`'s sheet: a
/// click chooses an element, outlined, and the column shows its style by section (Text, Layout, Fill), each row the
/// design system's tokens as chips or swatches (so a hand edit stays in the system), with the way back to its parent;
/// a double click on an element of text alone types over it (Enter keeps, Esc drops). To `kelpSync`: `selected` (to
/// choose it again once the canvas is drawn again), `style` and `text`, which the tab writes into the board's file by
/// the element's data-id (`BoardEdit`).
enum CanvasEditMode {
    /// The column's words, by key: title, parent, asDrawn, noID, typeHint, choose, text, layout, fill, size, weight,
    /// colour, padding, gap, background, radius.
    typealias Labels = [String: String]

    static func source(tokens: [String: [String]], labels: Labels) -> String {
        let js = MarkdownTab.jsString
        let groups = ["color", "size", "space", "radius"].map { group in
            "\(group): [" + (tokens[group] ?? []).map(js).joined(separator: ", ") + "]"
        }
        let words = labels.sorted { $0.key < $1.key }.map { "\($0.key): \(js($0.value))" }.joined(separator: ", ")
        return """
            (function () {
              const K = window.kelpCanvas, C = window.kelpColumn; if (!K || !C) return;
              const T = { \(groups.joined(separator: ", ")) };
              const L = { \(words) };
            \(body)
            })();
            """
    }

    private static let body = """
          const chosen = K.el('div', 'kelp-chosen'), tag = K.el('div', 'kelp-tag');
          K.layer.append(chosen, tag);
          let at = null;
          const idOf = e => e.getAttribute('data-id');
          const nameOf = e => e.tagName.toLowerCase() + (idOf(e) ? ' · ' + idOf(e) : '');
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
          function choose(next, quiet) {
            at = next;
            chosen.style.display = tag.style.display = at ? 'block' : 'none';
            const which = at ? { board: at.f.dataset.board, id: idOf(at.e) } : {};
            if (!quiet) K.post(Object.assign({ kind: 'selected' }, which));
            if (K.mode() !== 'edit') return;
            if (at) { tag.textContent = nameOf(at.e); outline(); }
            C.open([K.el('span', 'kelp-grow', L.title)], at ? fill() : [K.el('p', 'kelp-note', L.choose)]);
          }
          window.kelpSelect = (board, id) => {
            const f = K.light(board), e = f && f.contentDocument
              && f.contentDocument.querySelector('[data-id="' + CSS.escape(id) + '"]');
            if (e) choose({ f, e }, true);
          };
          addEventListener('kelp-zoom', outline);
          // A token's value in the board's own page, for its swatch.
          const valueOf = (e, name) => e.ownerDocument.defaultView.getComputedStyle(e.ownerDocument.documentElement)
            .getPropertyValue(name).trim();
          const rows = [
            ['text', [['size', 'font-size', 'size'], ['weight', 'font-weight', null], ['colour', 'color', 'color']]],
            ['layout', [['padding', 'padding', 'space'], ['gap', 'gap', 'space']]],
            ['fill', [['background', 'background', 'color'], ['radius', 'border-radius', 'radius']]]
          ];
          function fill() {
            const e = at.e, id = idOf(e), out = [];
            const path = [], up = K.el('button', 'kelp-pill', '↑ ' + L.parent);
            for (let p = e.parentElement; p && p !== e.ownerDocument.body && path.length < 3; p = p.parentElement)
              path.unshift(idOf(p) || p.tagName.toLowerCase());
            up.onclick = () => {
              const p = e.parentElement;
              if (p && p !== e.ownerDocument.body) choose({ f: at.f, e: p });
            };
            const where = K.el('div', 'kelp-row');
            where.append(K.el('span', 'kelp-grow kelp-what kelp-q', path.join(' › ')), up);
            const what = K.el('div', 'kelp-row');
            what.append(K.el('b', 'kelp-grow', nameOf(e)));
            out.push(where, what);
            if (!id) return [...out, K.el('p', 'kelp-note', L.noID)];
            for (const [section, items] of rows) {
              out.push(K.el('div', 'kelp-sec', L[section]));
              for (const [word, property, group] of items) {
                const choices = group
                  ? T[group].map(n => ['var(--' + (group === 'color' ? n : group + '-' + n) + ')', n])
                  : ['400', '500', '600'].map(w => [w, w]);
                if (!choices.length) continue;
                const set = e.style.getPropertyValue(property).trim();
                const line = K.el('div', 'kelp-prop'), list = K.el('div', 'kelp-choices');
                line.append(K.el('span', 'kelp-q', L[word]), list);
                const pick = value => {
                  if (value) e.style.setProperty(property, value); else e.style.removeProperty(property);
                  outline();
                  K.post({ kind: 'style', board: at.f.dataset.board, id, property, value: value || null });
                  C.open([K.el('span', 'kelp-grow', L.title)], fill());
                };
                const none = K.el('button', 'kelp-chip' + (set ? '' : ' drawn'), L.asDrawn);
                none.onclick = () => pick(null);
                list.append(none);
                for (const [value, name] of choices) {
                  const look = (group === 'color' ? 'kelp-swatch' : 'kelp-chip') + (value === set ? ' on' : '');
                  const b = K.el('button', look,
                    group === 'color' ? '' : name);
                  if (group === 'color') b.style.background = valueOf(e, '--' + name);
                  b.title = name;
                  b.onclick = () => pick(value);
                  list.append(b);
                }
                out.push(line);
              }
            }
            if (!e.children.length && e.textContent.trim()) out.push(K.el('p', 'kelp-note', L.typeHint));
            return out;
          }
          K.sheet.addEventListener('click', ev => { if (K.mode() === 'edit') choose(K.under(ev, true)); });
          K.sheet.addEventListener('dblclick', ev => {
            const hit = K.mode() === 'edit' && K.under(ev, true);
            if (hit && !hit.e.children.length && hit.e.textContent.trim()) typeOver(hit);
          });
          // A field of the page's own over the element: the board's frame runs no script, so typing in it is unheard.
          function typeOver(hit) {
            const e = hit.e, look = e.ownerDocument.defaultView.getComputedStyle(e), b = K.box(hit.f, e);
            const k = b.w / (e.getBoundingClientRect().width || 1), old = e.textContent.trim();
            const field = K.el('textarea', 'kelp-type');
            field.value = old;
            Object.assign(field.style, {
              left: b.x + 'px', top: b.y + 'px', width: Math.max(b.w, 60) + 'px', height: Math.max(b.h, 20) + 'px',
              fontFamily: look.fontFamily, fontWeight: look.fontWeight, fontSize: parseFloat(look.fontSize) * k + 'px',
              lineHeight: (parseFloat(look.lineHeight) || parseFloat(look.fontSize) * 1.3) * k + 'px',
              color: look.color, textAlign: look.textAlign, letterSpacing: look.letterSpacing
            });
            document.body.append(field);
            e.style.visibility = 'hidden';
            field.focus();
            field.select();
            const done = keep => {
              if (!field.isConnected) return;
              field.remove();
              e.style.visibility = '';
              if (keep && field.value.trim() && field.value !== old) {
                e.textContent = field.value;
                K.post({ kind: 'text', board: hit.f.dataset.board, id: idOf(e), old, text: field.value });
              }
              outline();
            };
            field.addEventListener('keydown', ev => {
              if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); done(true); }
              if (ev.key === 'Escape') { ev.preventDefault(); done(false); }
            });
            field.addEventListener('blur', () => done(true));
          }
        """

    /// The chosen element's outline and name, the column's rows of choices, and the field typed over an element.
    static let style = """
        .kelp-chosen { position: absolute; display: none; border: 2px solid var(--k-accent); border-radius: 3px; }
        .kelp-tag { position: absolute; display: none; height: 16px; padding: 0 5px; border-radius: 4px;
          background: var(--k-accent); color: #fff; font: 500 10px/16px -apple-system, sans-serif;
          white-space: nowrap; }
        .kelp-q { color: var(--k-sec); }
        .kelp-prop { display: grid; grid-template-columns: 70px 1fr; gap: 8px; align-items: start; padding: 4px 12px; }
        .kelp-prop > span { padding-top: 3px; }
        .kelp-choices { display: flex; flex-wrap: wrap; gap: 4px; }
        .kelp-chip { height: 20px; padding: 0 7px; border: 0; border-radius: 4px; background: var(--k-hover);
          color: var(--k-label); font: 11px -apple-system, sans-serif; }
        .kelp-chip:hover { background: var(--k-sel); }
        .kelp-chip.on { background: var(--k-accent); color: #fff; }
        .kelp-chip.drawn { background: var(--k-sel); font-weight: 500; }
        .kelp-swatch { width: 18px; height: 18px; border: 0; border-radius: 4px;
          box-shadow: inset 0 0 0 1px var(--k-sep); }
        .kelp-swatch.on { box-shadow: 0 0 0 2px var(--k-win), 0 0 0 3.5px var(--k-accent); }
        .kelp-type { position: absolute; z-index: 26; margin: 0; padding: 0; border: 0; resize: none;
          overflow: hidden; background: rgba(0,122,255,.08); outline: 2px solid var(--k-accent); border-radius: 2px; }
        """
}
