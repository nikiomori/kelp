import Foundation

extension MarkColumn {
    /// The column's drafts' parts: the circle that leaves one out of the send, ⋮⋮ to reorder, and the example picture
    /// pasted or dropped into a note. Function declarations, so they sit anywhere in the column's script.
    static let helpers = """
        // Whether a draft goes with the next send: a circle, filled when it does.
        function check(m) {
          const c = el('button', 'kelp-check' + (skip.has(m.id) ? '' : ' on'));
          c.onclick = e => { e.stopPropagation(); skip.has(m.id) ? skip.delete(m.id) : skip.add(m.id); draw(); };
          return c;
        }
        // ⋮⋮: dragged over another draft, puts this one before it, in the order the agent will do them.
        function grip(m, box) {
          const g = el('span', 'kelp-grip', '⋮⋮');
          g.onmousedown = () => { box.draggable = true; };
          box.ondragstart = e => { e.dataTransfer.setData('text/kelp-mark', String(by('draft').indexOf(m))); };
          box.ondragend = () => { box.draggable = false; };
          box.ondragover = e => { if (e.dataTransfer.types.includes('text/kelp-mark')) e.preventDefault(); };
          box.ondrop = e => {
            e.preventDefault();
            const d = by('draft'), moved = d[+e.dataTransfer.getData('text/kelp-mark')];
            if (!moved || moved === m) return;
            M.marks = M.marks.filter(k => k !== moved);
            M.marks.splice(M.marks.indexOf(m), 0, moved);
            keep(); draw();
          };
          return g;
        }
        """
}
