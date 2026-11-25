import Foundation

extension MarkColumn {
    /// The column's drafts' parts: ⋮⋮ to reorder, and the example picture pasted or dropped into a note. Function declarations, so they sit anywhere in the column's script.
    static let helpers = """
        // ⋮⋮: dragged over another draft, puts this one before it, in the order the agent will do them.
        function grip(m, box) {
          const g = el('span', 'kelp-grip kelp-sym-line-3-horizontal');
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
        // ?: the note is a question for the agent, answered without changing the page (a leading "?").
        function questionToggle(note, m) {
          const b = el('button', 'kelp-ib kelp-ask-toggle', '?');
          const shown = () => b.classList.toggle('on', note.value.startsWith('?'));
          b.title = L.asQuestion;
          b.onclick = () => {
            note.value = note.value.startsWith('?') ? note.value.slice(1).trimStart() : '? ' + note.value;
            const d = by('draft').find(d => d.id === m.id);
            if (d) d.note = note.value;
            keep(); shown();
          };
          note.addEventListener('input', shown);
          shown();
          return b;
        }
        // The agent's question, and its choices (`kelp artifact ask … --choice`), a line each: a click answers and
        // sends.
        function asked(m, body) {
          const [question, ...choices] = m.asked.split('\\n• ');
          body.append(el('div', 'kelp-said', question));
          const row = el('div', 'kelp-row kelp-choices');
          for (const c of choices) {
            const b = el('button', 'kelp-pill', c);
            b.onclick = () => {
              const d = by('draft').find(d => d.id === m.id);
              if (d) d.note = c;
              keep(); send();
            };
            row.append(b);
          }
          if (choices.length) body.append(row);
        }
        """
}
