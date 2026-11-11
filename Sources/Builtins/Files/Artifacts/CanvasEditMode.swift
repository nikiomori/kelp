import Foundation

/// Edit on a canvas, by hand, without the agent (`kelpEdit(true)` from the bar), on top of `CanvasEdit`'s sheet: a
/// click chooses an element and a panel shows its style, each row a list of the design system's tokens (so a hand edit
/// stays in the system); a double click on an element of text alone types over it (Enter keeps, Esc drops). To
/// `kelpSync`: `selected` (to choose it again once the canvas is drawn again), `style` and `text`, which the tab writes
/// into the board's file by the element's data-id (`BoardEdit`).
enum CanvasEditMode {
    struct Labels {
        var parent: String, none: String, noID: String, typeHint: String
    }

    static func source(tokens: [String: [String]], labels: Labels) -> String {
        let js = MarkdownTab.jsString
        let groups = ["color", "size", "space", "radius"].map { group in
            "\(group): [" + (tokens[group] ?? []).map(js).joined(separator: ", ") + "]"
        }
        let l = labels
        return """
            (function () {
              const K = window.kelpCanvas; if (!K) return;
              const T = { \(groups.joined(separator: ", ")) };
              const L = { parent: \(js(l.parent)), none: \(js(l.none)), noID: \(js(l.noID)),
                typeHint: \(js(l.typeHint)) };
            \(body)
            })();
            """
    }

    private static let body = """
          const chosen = K.el('div', 'kelp-chosen'), panel = K.el('div', 'kelp-props');
          K.layer.append(chosen);
          document.body.append(panel);
          let at = null;
          const idOf = e => e.getAttribute('data-id');
          window.kelpEdit = on => {
            K.setMode(on ? 'edit' : K.mode() === 'edit' ? null : K.mode());
            if (!on) choose(null, true);
          };
          function choose(next, quiet) {
            at = next;
            chosen.style.display = at ? 'block' : 'none';
            panel.style.display = at ? 'flex' : 'none';
            const which = at ? { board: at.f.dataset.board, id: idOf(at.e) } : {};
            if (!quiet) K.post(Object.assign({ kind: 'selected' }, which));
            if (at) { K.place(chosen, K.box(at.f, at.e)); fill(); }
          }
          window.kelpSelect = (board, id) => {
            const f = K.light(board), e = f && f.contentDocument
              && f.contentDocument.querySelector('[data-id="' + CSS.escape(id) + '"]');
            if (e) choose({ f, e }, true);
          };
          // A computed colour as #rrggbb (none for transparent); anything else as it is.
          const said = v => {
            const m = v.match(/^rgba?\\(([^)]+)\\)/); if (!m) return v;
            const p = m[1].split(/[ ,\\/]+/).filter(Boolean).map(Number);
            if (p.length > 3 && p[3] === 0) return 'none';
            return '#' + p.slice(0, 3).map(n => Math.round(n).toString(16).padStart(2, '0')).join('');
          };
          const rows = [['color', 'color'], ['background', 'color'], ['font-size', 'size'], ['font-weight', null],
            ['padding', 'space'], ['gap', 'space'], ['border-radius', 'radius']];
          function fill() {
            panel.replaceChildren();
            const e = at.e, id = idOf(e), shown = e.ownerDocument.defaultView.getComputedStyle(e);
            const head = K.el('div', 'kelp-props-head'), up = K.el('button', null, L.parent);
            up.onclick = () => {
              const p = e.parentElement;
              if (p && p !== e.ownerDocument.body) choose({ f: at.f, e: p });
            };
            head.append(K.el('b', null, id ? '[data-id=' + id + ']' : e.tagName.toLowerCase()), up);
            panel.append(head);
            if (!id) return panel.append(K.el('p', 'kelp-props-note', L.noID));
            for (const [property, group] of rows) {
              const choices = group
                ? T[group].map(n => ['var(--' + (group === 'color' ? n : group + '-' + n) + ')', n])
                : ['400', '500', '600', '700'].map(w => [w, w]);
              if (!choices.length) continue;
              const line = K.el('label', null, property), list = K.el('select');
              const set = e.style.getPropertyValue(property).trim();
              list.append(new Option(L.none + ' · ' + said(shown.getPropertyValue(property)), ''));
              for (const [value, name] of choices) list.append(new Option(name, value, false, value === set));
              list.onchange = () => {
                if (list.value) e.style.setProperty(property, list.value); else e.style.removeProperty(property);
                K.place(chosen, K.box(at.f, e));
                K.post({ kind: 'style', board: at.f.dataset.board, id, property, value: list.value || null });
              };
              line.append(list);
              panel.append(line);
            }
            if (!e.children.length && e.textContent.trim()) panel.append(K.el('p', 'kelp-props-note', L.typeHint));
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
              if (at) K.place(chosen, K.box(at.f, at.e));
            };
            field.addEventListener('keydown', ev => {
              if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); done(true); }
              if (ev.key === 'Escape') { ev.preventDefault(); done(false); }
            });
            field.addEventListener('blur', () => done(true));
          }
        """

    /// The style of the chosen element's outline, the panel and the field typed over an element.
    static let style = """
        .kelp-chosen { position: absolute; display: none; border: 2px solid #2f7dd6; border-radius: 3px; }
        .kelp-props { position: fixed; right: 14px; top: 14px; width: 230px; display: none; flex-direction: column;
          gap: 7px; padding: 10px 12px; border-radius: 10px; z-index: 25; background: rgba(40,41,44,.96);
          color: #ececec; box-shadow: 0 8px 24px rgba(0,0,0,.35); font: 11px/1.4 -apple-system, sans-serif; }
        .kelp-props-head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
        .kelp-props-head b { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .kelp-props button { border: 0; border-radius: 5px; padding: 1px 8px; font: inherit;
          background: rgba(255,255,255,.12); color: inherit; }
        .kelp-props label { display: flex; justify-content: space-between; align-items: center; gap: 8px;
          opacity: .9; }
        .kelp-props select { width: 130px; font: inherit; color: inherit; background: rgba(255,255,255,.08);
          border: 0; border-radius: 5px; padding: 2px 4px; }
        .kelp-props-note { margin: 0; opacity: .6; }
        .kelp-type { position: absolute; z-index: 26; margin: 0; padding: 0; border: 0; resize: none;
          overflow: hidden; background: rgba(47,125,214,.08); outline: 2px solid #2f7dd6; border-radius: 2px; }
        """
}
