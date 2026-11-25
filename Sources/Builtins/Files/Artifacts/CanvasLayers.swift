import Foundation

/// Edit's column gets the board's layers on top: the chosen element's ancestors, itself, its siblings and its
/// children, as a tree whose rows choose (Bolt, v0, Cursor). With the tree focused, ↑ goes to the parent, ↓ inside,
/// ⇥ to the next sibling, so a whole card is taken rather than its text. Under it, "All like this" when the element's
/// class is shared: a change by hand goes to every element of that class on every board (`like` on the style
/// messages). A mark gets the same choice in the marks column (`kelpCanvas.hooks.likeOf`).
enum CanvasLayers {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas, props = window.kelpProps; if (!K || !props) return;
          const name = e => e.getAttribute('data-title') || e.getAttribute('data-id') || e.tagName.toLowerCase()
            + (e.classList[0] ? '.' + e.classList[0] : '');
          // A row's own controls, as on the motion page's lanes: hidden, locked, its name, its place among its kin.
          const css = e => e.ownerDocument.defaultView.getComputedStyle(e);
          function toggle(at, n, sym, on, tip, run) {
            const b = K.el('button', 'kelp-lbtn' + (on ? ' on' : ''));
            b.append(K.el('span', 'kelp-sym-' + sym.replaceAll('.', '-'))); b.title = tip;
            b.onclick = ev => { ev.stopPropagation(); run(K.need(at.f, n)); };
            return b;
          }
          function controls(at, n, r) {
            const board = at.f.dataset.board, hidden = css(n).visibility === 'hidden';
            const locked = n.getAttribute('data-locked') === 'true';
            r.append(
              toggle(at, n, hidden ? 'eye.slash' : 'eye', hidden, L.hideLayer, id => {
                n.style.visibility = hidden ? '' : 'hidden';
                K.post({ kind: 'style', board, id, property: 'visibility', value: hidden ? null : 'hidden' });
              }),
              toggle(at, n, locked ? 'lock' : 'lock.open', locked, L.lockLayer, id => {
                if (locked) n.removeAttribute('data-locked'); else n.setAttribute('data-locked', 'true');
                K.post({ kind: 'attribute', board, id, name: 'data-locked', value: locked ? null : 'true' });
              }));
            // A double click names it (data-title); dragged onto a sibling, it stacks just above that one.
            r.ondblclick = () => {
              const input = K.el('input', 'kelp-lname'); input.value = name(n);
              r.firstChild.replaceWith(input); input.focus(); input.select();
              const done = keep => {
                const v = input.value.trim();
                if (keep && v && v !== name(n))
                  K.post({ kind: 'attribute', board, id: K.need(at.f, n), name: 'data-title', value: v });
                props.choose(at);
              };
              input.onkeydown = ev => {
                ev.stopPropagation();
                if (ev.key === 'Enter' || ev.key === 'Escape') done(ev.key === 'Enter');
              };
              input.onblur = () => done(true);
            };
            r.draggable = true;
            r.ondragstart = ev => { ev.dataTransfer.setData('text/kelp-layer', ''); window.kelpDragged = n; };
            r.ondragover = ev => { if (window.kelpDragged?.parentElement === n.parentElement) ev.preventDefault(); };
            r.ondrop = ev => {
              ev.preventDefault();
              const moved = window.kelpDragged; window.kelpDragged = null;
              if (!moved || moved === n || moved.parentElement !== n.parentElement) return;
              const kin = [...n.parentElement.children].filter(c => c !== moved);
              kin.splice(kin.indexOf(n) + 1, 0, moved);   // above it: later in the stack
              K.post({ kind: 'restyle', board, what: 'stacking', changes: kin.map((c, i) =>
                ({ id: K.need(at.f, c), props: { position: css(c).position === 'static' ? 'relative' : null,
                  'z-index': String(i + 1) } })) });
            };
          }
          let likeOn = false;
          // The element's first class that other elements share, and how many have it on how many boards.
          function shared(e) {
            for (const c of e.classList) {
              let count = 0; const on = new Set();
              for (const f of K.frames) {
                const n = f.contentDocument?.querySelectorAll('.' + CSS.escape(c)).length || 0;
                count += n; if (n) on.add(f.dataset.board);
              }
              if (count > 1) return { cls: c, count, boards: on.size, files: [...on] };
            }
            return null;
          }
          // For a change by hand: the class and the boards that have it, while All like this is on.
          props.like = e => {
            const s = likeOn && shared(e); return s ? { cls: s.cls, boards: s.files } : undefined;
          };
          addEventListener('kelp-chosen', () => { likeOn = false; });
          function tree(at) {
            const e = at.e, body = e.ownerDocument.body, rows = [];
            const chain = []; for (let p = e; p && p !== body; p = p.parentElement) chain.unshift(p);
            const add = (n, depth) => rows.push({ n, depth });
            chain.forEach((n, i) => {
              if (i < chain.length - 1) return add(n, i);
              const parent = n.parentElement;
              for (const s of parent ? [...parent.children] : [n]) {
                add(s, i);
                if (s === n) for (const c of [...n.children].slice(0, 12)) add(c, i + 1);
              }
            });
            const list = K.el('div', 'kelp-layers');
            list.tabIndex = 0;
            for (const { n, depth } of rows.slice(0, 40)) {
              const r = K.el('div', 'kelp-lrow' + (n === e ? ' on' : ''));
              r.append(K.el('span', 'kelp-lname-text', name(n)));
              r.style.paddingLeft = (6 + depth * 12) + 'px';
              r.onclick = () => props.choose({ f: at.f, e: n });
              controls(at, n, r);
              list.append(r);
            }
            list.addEventListener('keydown', ev => {
              const next = ev.key === 'ArrowUp' ? (e.parentElement !== body ? e.parentElement : null)
                : ev.key === 'ArrowDown' ? e.firstElementChild : ev.key === 'Tab' ? e.nextElementSibling : null;
              if (!['ArrowUp', 'ArrowDown', 'Tab'].includes(ev.key)) return;
              ev.preventDefault(); ev.stopPropagation();
              if (!next) return;
              props.choose({ f: at.f, e: next });
              setTimeout(() => document.querySelector('.kelp-layers')?.focus());   // the column was drawn again
            });
            const s = K.el('div', 'kelp-isec');
            s.append(K.el('div', 'kelp-ititle', L.layers), list, K.el('div', 'kelp-hint kelp-layers-keys', L.keys));
            const like = shared(e);
            if (like) {
              const box = K.el('label', 'kelp-like'), check = K.el('input');
              check.type = 'checkbox'; check.checked = likeOn;
              check.onchange = () => { likeOn = check.checked; };
              box.append(check, L.allLike + ' · .' + like.cls + ' ×' + like.count
                + (like.boards > 1 ? ' ' + L.onBoards.replace('%d', like.boards) : ''));
              s.append(box);
            }
            return [s];
          }
          props.top = (props.top || []).concat([tree]);
          // A mark's choice, for the marks column.
          if (K.hooks) K.hooks.likeOf = m => {
            const at = m.kind === 'element' ? K.find(m) : null;
            return at ? shared(at.e) : null;
          };
        """

    static let style = """
        .kelp-layers { max-height: 220px; overflow: auto; outline: none; border-radius: var(--k-radius-sm); }
        .kelp-layers:focus { box-shadow: inset 0 0 0 1px var(--k-accent); }
        .kelp-lrow { height: 24px; line-height: 24px; border-radius: var(--k-radius-xs);
          font-size: var(--k-text-row); white-space: nowrap;
          overflow: hidden; text-overflow: ellipsis; cursor: default; }
        .kelp-lrow:hover { background: var(--k-hover); }
        .kelp-lrow { display: flex; align-items: center; gap: 2px; padding-right: 4px; }
        .kelp-lname-text { flex: 1; overflow: hidden; text-overflow: ellipsis; }
        .kelp-lname { flex: 1; min-width: 0; font: inherit; }
        .kelp-lbtn { width: 18px; height: 18px; border: 0; background: none; color: var(--k-sec); padding: 0;
          visibility: hidden; border-radius: var(--k-radius-xs); }
        .kelp-lrow:hover .kelp-lbtn, .kelp-lbtn.on { visibility: visible; }
        .kelp-lbtn:hover { background: var(--k-hover); }
        .kelp-lrow.on { background: color-mix(in srgb, var(--k-accent) 35%, transparent); }
        .kelp-layers-keys { margin-top: 4px; }
        .kelp-like { display: flex; gap: 6px; align-items: center; margin-top: 6px; font-size: var(--k-text-caption); }
        """
}
