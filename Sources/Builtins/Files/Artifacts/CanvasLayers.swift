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
          const name = e => e.getAttribute('data-id') || e.tagName.toLowerCase()
            + (e.classList[0] ? '.' + e.classList[0] : '');
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
              const r = K.el('div', 'kelp-lrow' + (n === e ? ' on' : ''), name(n));
              r.style.paddingLeft = (6 + depth * 12) + 'px';
              r.onclick = () => props.choose({ f: at.f, e: n });
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
        .kelp-lrow { height: 22px; line-height: 22px; border-radius: var(--k-radius-xs);
          font-size: var(--k-text-row); white-space: nowrap;
          overflow: hidden; text-overflow: ellipsis; cursor: default; }
        .kelp-lrow:hover { background: var(--k-hover); }
        .kelp-lrow.on { background: color-mix(in srgb, var(--k-accent) 35%, transparent); }
        .kelp-layers-keys { margin-top: 4px; }
        .kelp-like { display: flex; gap: 6px; align-items: center; margin-top: 6px; font-size: var(--k-text-caption); }
        """
}
