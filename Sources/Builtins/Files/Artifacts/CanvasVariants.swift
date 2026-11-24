import Foundation

/// Variations of a board side by side (Claude Design, Figma, Gamma): a board's name row opens its menu on a right
/// click (Variations ×3…, Duplicate, Remove), and a board with variations (`"variant"` in canvas.json) and each of them
/// get Keep and Three More Like This in theirs. Each goes to the tab as a message.
enum CanvasVariants {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas; if (!K) return;
          const frames = [...document.querySelectorAll('.frame')];
          const boardOf = fr => fr.querySelector('iframe')?.dataset.board;
          const originals = new Set(frames.map(fr => fr.dataset.variant).filter(Boolean));
          for (const fr of frames) {
            const board = boardOf(fr), name = fr.querySelector('.name');
            if (!board || !name || fr.querySelector('iframe')?.dataset.theme === 'dark') continue;
            name.addEventListener('contextmenu', e => {
              e.preventDefault(); K.post({ kind: 'boardMenu', board });
            });
            const of = fr.dataset.variant || (originals.has(board) ? board : null);
            if (!of) continue;
            const keep = K.el('button', 'kelp-pill kelp-keep', L.keep), more = K.el('button', 'kelp-pill', L.more);
            keep.onclick = e => { e.stopPropagation(); K.post({ kind: 'keepVariant', board, of }); };
            more.onclick = e => { e.stopPropagation(); K.post({ kind: 'moreLike', board, of }); };
            name.append(keep, more);
          }
        """

    static let style = """
        .frame .name .kelp-pill { margin-left: 6px; font-size: calc(10px / var(--z, 1)); }
        .frame .name .kelp-keep { background: var(--k-accent); color: #fff; }
        """
}
