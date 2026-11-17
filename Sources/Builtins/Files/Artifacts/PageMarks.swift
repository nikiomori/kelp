import Foundation

/// Marks on an agent's Markdown page (a doc, slides), as on a canvas. With Mark on (`kelpMark(true)` from the bar),
/// text the user selects gets a number and a line in the column on the right (`window.kelpColumn`) for what should
/// change, and Send puts all the marks in one message. With Mark off, a selection shows a Mark button that turns Mark
/// on. The column's other list is the page's headings. Each time the page is drawn, a mark is found again by its text,
/// because the agent may have moved that text. The script sends `marks` (send), `marksDraft` (keep), and `mode` (Mark
/// turned on from the page) to `kelpSync`.
enum PageMarks {
    static func source(marks: [CanvasMark], labels: [String: String]) -> String {
        """
        (function () {
          const C = window.kelpColumn; if (!C) return;
          const marks = \(MarkdownTab.js(marks)), L = \(MarkdownTab.js(labels));
        \(body)
        })();
        """
    }

    private static let body = """
          const { el, post } = C;
          const root = document.querySelector('.markdown-body') || document.body;
          const layer = el('div', 'kelp-layer'), button = el('button', 'kelp-markbtn', L.mark);
          document.body.append(layer);
          document.documentElement.append(button);
          let on = false, tab = 'marks';
          // Where a mark's text is on the page now: its first place, spaces aside (a selection across blocks or cells
          // reads with line breaks the page's text doesn't have).
          function rangeOf(quote) {
            const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), nodes = [];
            let text = '';
            for (let n = walk.nextNode(); n; n = walk.nextNode()) {
              if (n.parentElement.closest('.kelp-thumbs')) continue;
              nodes.push([n, text.length]); text += n.data;
            }
            let flat = ''; const map = [];
            for (let i = 0; i < text.length; i++) if (!/\\s/.test(text[i])) { flat += text[i]; map.push(i); }
            const q = quote.replace(/\\s+/g, ''), i = q ? flat.indexOf(q) : -1;
            if (i < 0) return null;
            const at = x => {
              let k = nodes.length - 1;
              while (k > 0 && nodes[k][1] > x) k--;
              return [nodes[k][0], Math.min(x - nodes[k][1], nodes[k][0].length)];
            };
            const r = document.createRange();
            try { r.setStart(...at(map[i])); r.setEnd(...at(map[i + q.length - 1] + 1)); } catch (e) { return null; }
            return r;
          }
          const keep = () => post({ kind: 'marksDraft', marks: marks });
          function draw() {
            layer.replaceChildren();
            const ranges = [];
            marks.forEach((m, i) => {
              const r = rangeOf(m.text); if (!r) return;
              ranges.push(r);
              const rects = r.getClientRects(), last = rects[rects.length - 1];
              if (!last || !last.width) return;
              const pin = el('div', 'kelp-pin', String(i + 1));
              Object.assign(pin.style, { left: (last.right + scrollX - 6) + 'px',
                top: (last.top + scrollY - 14) + 'px' });
              layer.append(pin);
            });
            if (window.CSS && CSS.highlights) CSS.highlights.set('kelp-mark', new Highlight(...ranges));
            if (!on) return;
            const tabs = [['marks', L.marks + ' ' + marks.length]].concat(window.kelpSlides ? [] : [['contents',
              L.contents]]);
            C.open([C.tabs(tabs, tab, key => { tab = key; draw(); })], tab === 'marks' ? markRows() : contents());
          }
          function markRows() {
            if (!marks.length) return [el('p', 'kelp-note', L.noMarks)];
            const rows = [];
            marks.forEach((m, i) => {
              const head = el('div', 'kelp-row'), x = el('button', 'kelp-ib', '×');
              x.title = L.remove;
              x.onclick = () => { marks.splice(i, 1); keep(); draw(); };
              head.append(el('span', 'kelp-num', String(i + 1)), el('span', 'kelp-grow kelp-what kelp-quote',
                '«' + m.text + '»'), x);
              const note = el('input', 'kelp-field'), line = el('div', 'kelp-row kelp-indent');
              note.placeholder = L.note; note.value = m.note;
              note.addEventListener('change', () => { m.note = note.value; keep(); });
              note.addEventListener('keydown', e => {
                if (e.key === 'Enter' && e.metaKey) { m.note = note.value; send(); }
                else if (e.key === 'Enter') note.blur();
              });
              line.append(note);
              rows.push(head, line);
            });
            const go = el('button', 'kelp-prominent', L.send), foot = el('div', 'kelp-row kelp-end');
            go.onclick = send;
            foot.append(go);
            return [...rows, foot, el('p', 'kelp-note', L.hint)];
          }
          function send() {
            for (const i of document.querySelectorAll('.kelp-col input')) i.blur();
            post({ kind: 'marks', marks: marks }); marks.length = 0; keep(); draw();
          }
          function contents() {
            const heads = [...root.querySelectorAll('h1, h2, h3')];
            if (!heads.length) return [el('p', 'kelp-note', L.noContents)];
            return heads.map(h => {
              const b = el('button', 'kelp-toc kelp-toc' + h.tagName[1], h.textContent);
              b.onclick = () => h.scrollIntoView({ behavior: 'smooth', block: 'start' });
              return b;
            });
          }
          function add(text) {
            marks.push({ board: '', target: '', text: text, note: '' });
            tab = 'marks'; getSelection().removeAllRanges(); keep(); draw();
            const inputs = document.querySelectorAll('.kelp-col input'); inputs[inputs.length - 1]?.focus();
          }
          const chosen = () => {
            const s = getSelection(), t = String(s).trim();
            return t && s.rangeCount && root.contains(s.anchorNode) ? t.replace(/\\s+/g, ' ').slice(0, 300) : '';
          };
          const hide = () => { button.style.display = 'none'; };
          addEventListener('mouseup', e => {
            if (e.target === button || e.target.closest?.('.kelp-col')) return;
            setTimeout(() => {
              const t = chosen(); if (!t) return hide();
              if (on) return add(t);
              const r = getSelection().getRangeAt(0).getBoundingClientRect();
              Object.assign(button.style, { display: 'block', left: (r.left + scrollX) + 'px',
                top: (r.bottom + scrollY + 6) + 'px' });
            }, 0);
          });
          addEventListener('mousedown', e => { if (e.target !== button) hide(); });
          button.addEventListener('mousedown', e => e.preventDefault());   // keeps the selection
          button.addEventListener('click', () => {
            const t = chosen(); hide();
            post({ kind: 'mode', value: 'mark' }); window.kelpMark(true);
            if (t) add(t);
          });
          window.kelpMark = v => { on = v; if (!on) C.close(); draw(); };
          addEventListener('resize', () => requestAnimationFrame(draw));
          addEventListener('kelp-slide', draw);
          draw();
        """

    /// Shows what the agent's last turn changed in a doc. A bar goes beside each block that holds a changed line
    /// (`lines`, from `Artifacts.changedLines`), and `kelpChange(1)` scrolls to the next one. The number of changes
    /// goes to `kelpSync` as `changes`.
    static func changes(_ lines: [Int]) -> String {
        """
        (function () {
          const lines = \(MarkdownTab.js(lines));
          const marks = [...document.querySelectorAll('i[data-line]')].map(i => [+i.dataset.line, i]);
          const blocks = new Set();
          for (const l of lines) {
            let at = null;
            for (const [n, i] of marks) { if (n <= l) at = i; else break; }
            let b = at && at.nextElementSibling;
            if (b && b.tagName !== 'I') blocks.add(b);
          }
          const list = [...blocks];
          for (const b of list) b.classList.add('kelp-changed');
          let at = -1;
          window.kelpChange = d => {
            if (!list.length) return;
            at = (at + d + list.length) % list.length;
            list[at].scrollIntoView({ behavior: 'smooth', block: 'center' });
          };
          webkit.messageHandlers.kelpSync?.postMessage({ kind: 'changes', count: list.length });
        })();
        """
    }

    /// The CSS for the marks on the page, the Mark button and the bar beside a changed block, together with the CSS for
    /// the column (`CanvasChrome`).
    static let style = """
        <style>
        \(CanvasChrome.style)
        \(CanvasEdit.style)
        ::highlight(kelp-mark) { background-color: rgba(255,149,0,.28); }
        .kelp-markbtn { position: absolute; z-index: 2147483647; display: none; padding: 4px 10px; border: 0;
          border-radius: 999px; font: 500 12px -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--k-accent);
          color: #fff; box-shadow: 0 2px 6px rgba(0,0,0,.2); cursor: default; }
        .kelp-quote { font-style: italic; color: var(--k-sec); }
        .kelp-toc { display: block; width: 100%; text-align: left; border: 0; background: none; color: var(--k-label);
          font: inherit; padding: 4px 12px; border-radius: 0; white-space: nowrap; overflow: hidden;
            text-overflow: ellipsis; }
        .kelp-toc:hover { background: var(--k-hover); }
        .kelp-toc1 { font-weight: 600; }
        .kelp-toc3 { padding-left: 26px; color: var(--k-sec); }
        .kelp-changed:not(table) { border-left: 3px solid var(--k-accent); margin-left: -15px; padding-left: 12px; }
        table.kelp-changed { outline: 2px solid color-mix(in srgb, var(--k-accent) 45%, transparent);
          outline-offset: 2px; }
        @media print { .kelp-col, .kelp-layer, .kelp-markbtn { display: none !important; }
          .kelp-changed { border-left: 0 !important; margin-left: 0 !important; padding-left: 0 !important;
            outline: 0 !important; } }
        </style>
        """
}
