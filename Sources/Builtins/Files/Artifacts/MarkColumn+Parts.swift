import Foundation

extension MarkColumn {
    /// The column's drafts' parts: ⋮⋮ to reorder, and the example picture pasted or dropped into a note. Function declarations, so they sit anywhere in the column's script.
    static let helpers = """
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
