import Foundation

/// Where a mark's element is after the agent's turn (Open Design's anchors): in place, moved (its box shifted from
/// where it was marked), or gone. A gone element stays as a dashed ghost at its last place, with its pin, and Point
/// Again takes the next click on an element as the mark's new target, its note and its history kept. Built on
/// `CanvasEdit`'s hooks (`kelpCanvas.hooks`).
enum CanvasAnchors {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas, M = window.kelpMarks; if (!K || !K.hooks || !M) return;
          const hooks = K.hooks, where = hooks.where, draw = hooks.draw;
          let repointing = null;
          hooks.status = m => {
            if (m.kind !== 'element' || !m.board) return null;
            const at = K.find(m);
            if (!at) return m.area ? 'gone' : null;
            if (!m.area) return null;
            const r = at.e.getBoundingClientRect();
            return Math.abs(r.x - m.area[0]) > 8 || Math.abs(r.y - m.area[1]) > 8 ? 'moved' : null;
          };
          hooks.where = m => {
            const r = where(m); if (r || hooks.status(m) !== 'gone') return r;
            const f = K.light(m.board); return f ? K.inPage(f, ...m.area) : null;
          };
          hooks.draw = (m, into, r) => {
            draw(m, into, r);
            if (hooks.status(m) !== 'gone') return;
            const ghost = K.el('div', 'kelp-ghost'); K.place(ghost, r); into.append(ghost);
          };
          hooks.statusChip = (m, status) => {
            const chip = K.el('button', 'kelp-anchor kelp-anchor-' + status, status === 'gone' ? L.gone : L.moved);
            if (status === 'gone') {
              chip.title = L.pointAgain;
              chip.textContent = L.gone + ' · ' + L.pointAgain;
              chip.onclick = e => {
                e.stopPropagation(); repointing = m;
                if (K.mode() !== 'mark') window.kelpMark(true);
                document.body.classList.add('kelp-repointing');
              };
            }
            return chip;
          };
          // While pointing again, a click on an element is the mark's new target, not a new mark.
          K.claims.push(e => {
            if (!repointing) return false;
            const at = K.under(e); if (!at) return true;
            const m = Object.assign(repointing, { board: at.f.dataset.board }, K.describe(at.e));
            repointing = null;
            document.body.classList.remove('kelp-repointing');
            // A draft goes with the drafts; a mark sent or to check is changed on its own.
            if (m.state !== 'draft') K.post({ kind: 'markTarget', id: m.id, mark: m });
            M.changed();
            return true;
          });
        """

    static let style = """
        .kelp-anchor { flex: none; height: 16px; padding: 0 6px; border: 0; border-radius: 8px;
          font: 10px -apple-system, sans-serif;
          background: color-mix(in srgb, var(--k-orange) 20%, transparent); color: var(--k-orange); }
        .kelp-anchor-gone { background: color-mix(in srgb, var(--k-red, #ff453a) 20%, transparent);
          color: var(--k-red, #ff453a); }
        .kelp-ghost { position: absolute; border: 1.5px dashed var(--k-orange); border-radius: 4px; opacity: .7; }
        .kelp-repointing .kelp-sheet { cursor: crosshair; }
        """
}
