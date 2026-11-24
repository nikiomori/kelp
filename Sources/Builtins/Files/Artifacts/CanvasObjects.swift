import Foundation

/// Mark's element tool on a picture: the click asks Kelp for the object there (`objectAt`, which `ObjectOutline` finds
/// with Vision on this Mac), and the mark is its outline, drawn over the picture as a stroke, so the agent sees which
/// thing in it is meant. Where nothing stands out (sky, a wall), the mark is on the picture as a whole, as before.
enum CanvasObjects {
    static let source = """
        (function () {
          const K = window.kelpCanvas; if (!K) return;
          let pending = null;
          K.sheet.addEventListener('click', e => {
            if (K.mode() !== 'mark' || K.tool?.() !== 'element' || e.detail > 1) return;
            const at = K.under(e, true);
            if (!at || at.e.tagName !== 'IMG' || !at.e.currentSrc.startsWith('file:')) return;
            const fr = at.f.getBoundingClientRect(), k = fr.width / at.f.offsetWidth, r = at.e.getBoundingClientRect();
            const x = (e.clientX - fr.left) / k, y = (e.clientY - fr.top) / k;
            e.stopImmediatePropagation();
            pending = { at, box: [r.left, r.top, r.width, r.height] };
            K.post({ kind: 'objectAt', src: at.e.currentSrc, x: (x - r.left) / r.width, y: (y - r.top) / r.height });
          }, true);
          // Kelp's answer: the outline's points across and down the picture, or null for the picture as a whole.
          window.kelpObjectMark = points => {
            const p = pending; pending = null; if (!p) return;
            const board = p.at.f.dataset.board, [bx, by, bw, bh] = p.box;
            if (!points) return window.kelpMarks?.add(Object.assign({ kind: 'element', board }, K.describe(p.at.e)));
            const xy = points.map(([u, v]) => [bx + u * bw, by + v * bh]);
            const xs = xy.map(q => q[0]), ys = xy.map(q => q[1]), x0 = Math.min(...xs), y0 = Math.min(...ys);
            window.kelpMarks?.add({ kind: 'pen', board, target: K.describe(p.at.e).target,
              path: 'M' + xy.map(([x, y]) => Math.round(x) + ' ' + Math.round(y)).join(' L') + ' Z',
              area: [x0, y0, Math.max(...xs) - x0, Math.max(...ys) - y0].map(Math.round) });
          };
        })();
        """
}
