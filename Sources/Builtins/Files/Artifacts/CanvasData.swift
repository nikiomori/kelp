import Foundation

/// One page, a copy a row (`DataRows`): the elements with `data-field="file.csv:column"` show that column of the row
/// chosen (text, or a picture's address). Once drawn, the page asks for the files (`rowsNeed`) and Kelp gives their
/// rows (`kelpSetRows`). Edit's From Data chooses the table (`rowsTable`), the column (`rowsField`) and the row shown.
enum CanvasData {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas, props = window.kelpProps; if (!K) return;
          let rows = {}, at = 1;   // each file's rows (names first), and the row shown
          const kept = new Map();   // what an element showed before a row was put in it
          const bound = () => K.frames.flatMap(f => f.contentDocument
            ? [...f.contentDocument.querySelectorAll('[data-field]')] : []);
          const field = e => {
            const [file, col] = (e.getAttribute('data-field') || '').split(':'); return { file, col };
          };
          const count = () => Math.max(0, ...Object.values(rows).map(r => r.length - 1));
          const put = (e, v) => { if (e.tagName === 'IMG') e.setAttribute('src', v); else e.textContent = v; };
          function apply() {
            for (const [e, v] of kept) put(e, v);
            kept.clear();
            for (const e of bound()) {
              const { file, col } = field(e), table = rows[file]; if (!table || table.length < 2) continue;
              const i = table[0].indexOf(col), row = table[Math.min(at, table.length - 1)];
              if (i < 0 || !row) continue;
              kept.set(e, e.tagName === 'IMG' ? e.getAttribute('src') : e.textContent);
              put(e, row[i] ?? '');
            }
          }
          window.kelpSetRows = map => {
            rows = map || {}; at = Math.max(1, Math.min(at, count())); apply(); props?.redraw?.();
          };
          window.kelpRow = i => { at = i; apply(); props?.redraw?.(); };
          window.kelpRowNames = () => {
            const table = Object.values(rows)[0] || [];
            return table.slice(1).map(r => r[0] || '');
          };
          // Asked once the frames have loaded, not once a frame.
          let asking = 0;
          const need = () => {
            clearTimeout(asking);
            asking = setTimeout(() => {
              const files = [...new Set(bound().map(e => field(e).file).filter(Boolean))];
              if (files.length) K.post({ kind: 'rowsNeed', files });
            }, 50);
          };
          for (const f of K.frames) {
            f.addEventListener('load', need);
          }
          setTimeout(need, 0);
          if (!props) return;
          props.more = (props.more || []).concat([(e, id) => {
            const own = [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
            if (!own && e.tagName !== 'IMG') return [];
            const { file, col } = field(e), table = rows[file], board = props.at().f.dataset.board;
            const s = K.el('div', 'kelp-isec');
            s.append(K.el('div', 'kelp-ititle', L.fromData));
            const row = (label, control) => {
              const r = K.el('div', 'kelp-irow');
              r.append(K.el('span', 'kelp-ilabel', label), control, K.el('span'));
              s.append(r);
            };
            const pop = (title, post) => {
              const b = K.el('button', 'kelp-ipop');
              b.append(K.el('span', 'kelp-itok', title));
              b.onclick = () => K.post(Object.assign({}, post, { id: id || K.need(props.at().f, e) }));
              return b;
            };
            row(L.table, pop(file ? file + (table ? ' · ' + (table.length - 1) : '') : L.chooseTable,
              { kind: 'rowsTable', board, id }));
            if (file) row(L.field, pop(col || '—', { kind: 'rowsField', board, id, file, columns: table?.[0] || [] }));
            if (file && count()) {
              const seg = K.el('span', 'kelp-iseg');
              const step = d => { at = Math.max(1, Math.min(count(), at + d)); apply(); props.redraw(); };
              const back = K.el('button'), next = K.el('button');
              back.innerHTML = \(CanvasChrome.Glyph.back.js); next.innerHTML = \(CanvasChrome.Glyph.forward.js);
              back.onclick = () => step(-1); next.onclick = () => step(1);
              seg.append(back, K.el('button', 'on', at + ' / ' + count()), next);
              row(L.row, seg);
            }
            return [s];
          }]);
        """
}
