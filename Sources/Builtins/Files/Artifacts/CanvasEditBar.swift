import Foundation

/// The bar over the element chosen in Edit, on a board or a motion page's stage: what is changed most, where the eye
/// already is. A text's size, weight and colour (a box's background), its opacity, and ⋯ for its menu. Each opens the
/// same choices as the column's rows (`kelpProps.open`), and the bar follows the element; it steps aside while the
/// element is dragged or typed over, and sits under the element when there's no room above.
enum CanvasEditBar {
    static let source = """
        (function () {
          const K = window.kelpCanvas, props = window.kelpProps; if (!K || !props) return;
          const bar = K.el('div', 'kelp-ebar');
          bar.style.display = 'none';
          document.body.append(bar);
          let at = null;
          const button = (content, run, title) => {
            const b = K.el('button', 'kelp-ebtn');
            b.append(...content);
            b.onclick = ev => { ev.stopPropagation(); run(); };
            if (title) b.title = title;
            return b;
          };
          const sep = () => K.el('span', 'kelp-esep');
          function popup(key) {
            const s = props.shown(key, at.e), parts = [];
            if (s.swatch) { const w = K.el('span', 'kelp-iswatch'); w.style.background = s.swatch; parts.push(w); }
            else parts.push(s.title);
            parts.push(K.el('span', 'kelp-edown', '⌄'));
            return button(parts, () => props.open(key), s.title);
          }
          function draw() {
            const e = at && at.e;
            const on = e && K.mode() === 'edit' && e.getAttribute('data-id') && !window.kelpHandles?.busy()
              && !document.querySelector('.kelp-type');
            bar.style.display = on ? 'flex' : 'none';
            if (!on) return;
            const text = !e.children.length && e.textContent.trim();
            bar.replaceChildren(...(text ? ['size', 'weight', 'colour'] : ['background']).map(popup), sep(),
              button([props.shown('opacity', e).title], () => props.open('opacity')), sep(),
              button([K.el('span', 'kelp-sym-ellipsis')], () => K.post({ kind: 'menu', board: at.f.dataset.board,
                id: e.getAttribute('data-id'), image: e.tagName === 'IMG', media: /^(IMG|VIDEO)$/.test(e.tagName) })));
            const b = K.box(at.f, e), h = bar.offsetHeight || 28, gap = 8;
            const above = b.y - scrollY - h - gap - 18 > 0;   // the name tag sits right over the element
            Object.assign(bar.style, {
              left: Math.max(scrollX + 8, b.x) + 'px',
              top: (above ? b.y - h - gap - 18 : b.y + b.h + gap) + 'px'
            });
          }
          addEventListener('kelp-chosen', ev => { at = ev.detail; draw(); });
          for (const name of ['kelp-zoom', 'kelp-props', 'resize', 'mouseup']) addEventListener(name, () => draw());
          addEventListener('mousemove', () => { if (window.kelpHandles?.busy()) bar.style.display = 'none'; });
          addEventListener('focusout', () => setTimeout(draw));
        })();
        """

    /// The bar: the floating card of Kelp's pages, words 11, its buttons answering the pointer.
    static let style = """
        .kelp-ebar { position: absolute; z-index: 17; display: flex; align-items: center; gap: 2px; padding: 3px;
          border-radius: 8px; background: var(--k-float); box-shadow: 0 2px 6px rgba(0,0,0,.2);
          -webkit-backdrop-filter: blur(20px); font: 11px -apple-system, sans-serif; color: var(--k-label); }
        .kelp-ebtn { display: flex; align-items: center; gap: 4px; height: 22px; padding: 0 7px; border: 0;
          border-radius: 5px; background: none; color: inherit; font: inherit; font-variant-numeric: tabular-nums;
          white-space: nowrap; }
        .kelp-ebtn:hover { background: var(--k-hover); }
        .kelp-ebtn:active { background: var(--k-sel); }
        .kelp-ebtn .kelp-iswatch { margin: 0; }
        .kelp-edown { color: var(--k-sec); font-size: 10px; position: relative; top: -2px; }
        .kelp-esep { width: 1px; height: 14px; background: var(--k-sep); margin: 0 2px; }
        .kelp-rec .kelp-ebar { display: none !important; }
        """
}
