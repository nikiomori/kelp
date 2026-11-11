import Core
import Foundation

/// A mark the user put on a board (Mark on the canvas's bar): what it points at and what they said of it. Kept in the
/// artifact's `notes.json` until sent, so a canvas drawn again (the agent saved a board) or a tab reopened keeps them.
struct CanvasMark: Codable, Equatable, Sendable {
    var board: String
    /// `[data-id=title]`, or the element's tag when nothing around it has an id.
    var target: String
    /// The start of its text, so the agent knows which one without the id.
    var text: String
    var note: String

    static let file = "notes.json"

    /// The marks as one line to the chat, by board: `Marks on <file>: boards/A.html 1 [data-id=t] «Hi»: bigger; …`.
    static func message(_ marks: [CanvasMark], canvas: String) -> String {
        var n = 0
        let boards = Dictionary(grouping: marks, by: \.board).sorted { $0.key < $1.key }.map { board, marks in
            board + " "
                + marks.map { m in
                    n += 1
                    let text = m.text.isEmpty ? "" : " «\(m.text)»"
                    return "\(n) \(m.target)\(text): \(m.note.isEmpty ? "look at this" : m.note)"
                }.joined(separator: "; ")
        }
        return "Marks on \(canvas): " + boards.joined(separator: " | ")
    }

    /// The marks in a `notes.json`; none for a file that isn't one.
    static func read(_ data: Data?) -> [CanvasMark] {
        guard let data else { return [] }
        do { return try JSONDecoder().decode([CanvasMark].self, from: data) } catch { return [] }
    }
}

/// Kelp's script for what the user does on a canvas (`MarkdownTab.world`; the boards' own don't run): marks on elements
/// (`kelpMark(true)` from the bar; a click outlines the element, a number lands on it, the column on the right holds
/// the notes and sends them), Pick on each row, each board's tweaks moved live and saved, and Present
/// (`kelpPresent(true)`: the boards one at a time, each as large as the pane; ← → step, Esc ends). To `kelpSync`:
/// `marks` (send), `marksDraft` (keep), `pick`, `tweak`, `present` (ended).
enum CanvasEdit {
    struct Labels {
        var send: String, pick: String, tweaks: String, note: String, remove: String
        var marks: String, check: String, askFix: String, noMarks: String, noIssues: String, of: String, escEnds: String
    }

    static func source(marks: [CanvasMark], tweaks: [String: [Tweak]], labels: Labels) -> String {
        let js = MarkdownTab.jsString
        let marksJSON =
            "["
            + marks.map {
                "{board: \(js($0.board)), target: \(js($0.target)), text: \(js($0.text)), note: \(js($0.note))}"
            }.joined(separator: ", ") + "]"
        let tweaksJSON =
            "{"
            + tweaks.map { board, list in
                js(board) + ": ["
                    + list.map { t in
                        let options = t.options.map(js).joined(separator: ", ")
                        return "{name: \(js(t.name)), value: \(js(t.value)), options: [\(options)]}"
                    }.joined(separator: ", ") + "]"
            }.joined(separator: ", ") + "}"
        let l = labels
        return """
            (function () {
              const marks = \(marksJSON), tweaks = \(tweaksJSON);
              const L = { send: \(js(l.send)), pick: \(js(l.pick)), tweaks: \(js(l.tweaks)), note: \(js(l.note)),
                remove: \(js(l.remove)), marks: \(js(l.marks)), check: \(js(l.check)), askFix: \(js(l.askFix)),
                noMarks: \(js(l.noMarks)), noIssues: \(js(l.noIssues)), of: \(js(l.of)), escEnds: \(js(l.escEnds)) };
            \(body)
            })();
            """
    }

    private static let body = """
          const post = m => webkit.messageHandlers.kelpSync?.postMessage(m);
          const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls;
            if (text != null) e.textContent = text; return e; };
          const layer = el('div', 'kelp-layer'), outline = el('div', 'kelp-outline');
          // While marking, a sheet over the canvas takes the pointer: a board's frame runs no script, its own listeners
          // included, so what's under the pointer is asked of the frame (elementFromPoint).
          const sheet = el('div', 'kelp-sheet');
          document.body.append(layer, sheet);
          layer.append(outline);
          const frames = [...document.querySelectorAll('iframe[data-board]')];
          const light = b => frames.find(f => f.dataset.board === b && f.dataset.theme !== 'dark')
            || frames.find(f => f.dataset.board === b);
          // What a click on a board does: mark it (Mark), choose it for the properties panel (Edit), or nothing.
          let mode = null;
          const setMode = m => {
            mode = m; outline.style.display = 'none'; sheet.style.display = m ? 'block' : 'none';
          };
          window.kelpMark = on => {
            setMode(on ? 'mark' : mode === 'mark' ? null : mode);
            if (on) draw(); else if (mode !== 'edit') window.kelpColumn?.close();
          };
          const pointed = e => e.closest('[data-id]') || e;
          const describe = e => {
            const d = e.closest('[data-id]');
            return { target: d ? '[data-id=' + d.getAttribute('data-id') + ']' : e.tagName.toLowerCase(),
              text: (e.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 60) };
          };
          function box(f, e) {
            const fr = f.getBoundingClientRect(), r = e.getBoundingClientRect(), k = fr.width / f.offsetWidth;
            return {
              x: fr.left + scrollX + r.left * k, y: fr.top + scrollY + r.top * k, w: r.width * k, h: r.height * k
            };
          }
          const place = (n, b) =>
            Object.assign(n.style, { left: b.x + 'px', top: b.y + 'px', width: b.w + 'px', height: b.h + 'px' });
          function find(m) {
            const f = light(m.board), doc = f && f.contentDocument;
            if (!doc) return null;
            const id = m.target.match(/^\\[data-id=(.*)\\]$/);
            const e = id ? doc.querySelector('[data-id="' + CSS.escape(id[1]) + '"]') : null;
            return e ? { f, e } : null;
          }
          const keep = () => post({ kind: 'marksDraft', marks: marks });
          // Pins on the boards; while marking, the column lists the marks (each with its note) or the check's findings.
          let tab = 'marks';
          function draw() {
            for (const p of layer.querySelectorAll('.kelp-pin')) p.remove();
            marks.forEach((m, i) => {
              const at = find(m); if (!at) return;
              const b = box(at.f, at.e), pin = el('div', 'kelp-pin', String(i + 1));
              Object.assign(pin.style, { left: (b.x + b.w - 9) + 'px', top: (b.y - 9) + 'px' });
              layer.append(pin);
            });
            if (mode !== 'mark' || !window.kelpColumn) return;
            const issues = window.kelpIssues || [], seg = el('span', 'kelp-seg');
            const tabs = [['marks', L.marks + ' ' + marks.length], ['check', L.check + ' ' + issues.length]];
            for (const [key, name] of tabs) {
              const b = el('button', key === tab ? 'on' : '', name);
              b.onclick = () => { tab = key; draw(); };
              seg.append(b);
            }
            window.kelpColumn.open([seg], tab === 'marks' ? markRows() : checkRows(issues));
          }
          function markRows() {
            if (!marks.length) return [el('p', 'kelp-note', L.noMarks)];
            const rows = [];
            marks.forEach((m, i) => {
              const head = el('div', 'kelp-row'), x = el('button', 'kelp-ib', '×');
              x.title = L.remove;
              x.onclick = () => { marks.splice(i, 1); keep(); draw(); };
              head.append(el('span', 'kelp-num', String(i + 1)), el('span', 'kelp-grow kelp-what', m.target
                + (m.text ? ' «' + m.text + '»' : '')), x);
              const note = el('input', 'kelp-field'), line = el('div', 'kelp-row kelp-indent');
              note.placeholder = L.note; note.value = m.note;
              note.addEventListener('change', () => { m.note = note.value; keep(); });
              note.addEventListener('keydown', e => { if (e.key === 'Enter') note.blur(); });
              line.append(note);
              rows.push(head, line);
            });
            const send = el('button', 'kelp-prominent', L.send), foot = el('div', 'kelp-row kelp-end');
            send.onclick = () => {
              for (const i of document.querySelectorAll('.kelp-col input')) i.blur();
              post({ kind: 'marks', marks: marks }); marks.length = 0; draw();
            };
            foot.append(send);
            return [...rows, foot];
          }
          function checkRows(issues) {
            if (!issues.length) return [el('p', 'kelp-note', L.noIssues)];
            const rows = issues.map(t => {
              const r = el('div', 'kelp-row kelp-issue');
              r.append(el('span', 'kelp-mark-warn', '!'), el('span', 'kelp-grow', t));
              return r;
            });
            const fix = el('button', 'kelp-pill', L.askFix), foot = el('div', 'kelp-row kelp-end');
            fix.onclick = () => post({ kind: 'fixCheck' });
            foot.append(fix);
            return [...rows, foot];
          }
          addEventListener('kelp-check', draw);
          function under(e, raw) {
            for (const f of frames) {
              const r = f.getBoundingClientRect(), k = r.width / f.offsetWidth, doc = f.contentDocument;
              const outside = e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
              if (!doc || outside) continue;
              const hit = doc.elementFromPoint((e.clientX - r.left) / k, (e.clientY - r.top) / k);
              return hit && hit !== doc.documentElement && hit !== doc.body ? { f, e: raw ? hit : pointed(hit) } : null;
            }
            return null;
          }
          sheet.addEventListener('mousemove', e => {
            const at = under(e, mode === 'edit');
            outline.style.display = at ? 'block' : 'none';
            if (at) place(outline, box(at.f, at.e));
          });
          sheet.addEventListener('click', e => {
            const at = mode === 'mark' && under(e); if (!at) return;
            marks.push(Object.assign({ board: at.f.dataset.board, note: '' }, describe(at.e)));
            tab = 'marks'; keep(); draw();
            const inputs = document.querySelectorAll('.kelp-col input'); inputs[inputs.length - 1]?.focus();
          });
          for (const f of frames) f.addEventListener('load', draw);
          window.kelpCanvas = { frames, light, box, place, el, post, sheet, layer, under, setMode, mode: () => mode };
          for (const h of document.querySelectorAll('.row h2')) {
            const b = el('button', 'kelp-pick', L.pick);
            b.onclick = () => post({ kind: 'pick', row: h.firstChild.textContent });
            h.append(b);
          }
          for (const frame of document.querySelectorAll('.frame')) {
            const f = frame.querySelector('iframe'), list = f && tweaks[f.dataset.board];
            if (!list || !list.length || f.dataset.theme === 'dark') continue;
            const open = el('button', 'kelp-tweaks', L.tweaks), panel = el('div', 'kelp-panel');
            open.onclick = () => panel.classList.toggle('open');
            frame.querySelector('.name').append(open);
            frame.insertBefore(panel, f);
            const set = (t, v, save) => {
              for (const g of frames) if (g.dataset.board === f.dataset.board && g.contentDocument)
                g.contentDocument.documentElement.style.setProperty(t.name, v);
              if (save) post({ kind: 'tweak', board: f.dataset.board, name: t.name, value: v });
            };
            for (const t of list) {
              const line = el('label', null, t.name.slice(2));
              if (!t.options.length && t.value.startsWith('#')) {
                const c = el('input'); c.type = 'color'; c.value = t.value;
                c.oninput = () => set(t, c.value, false); c.onchange = () => set(t, c.value, true);
                line.append(c);
              } else {
                const seg = el('span', 'kelp-tseg');
                for (const o of t.options) {
                  const b = el('button', o === t.value ? 'on' : '', o);
                  b.onclick = () => {
                    for (const s of seg.children) s.className = '';
                    b.className = 'on'; set(t, o, true);
                  };
                  seg.append(b);
                }
                line.append(seg);
              }
              panel.append(line);
            }
          }
          const slides = [...new Set(frames.map(f => f.dataset.board))].map(light);
          let at = -1, quiet = null;
          // A strip at the foot while presenting: where you are, ‹ ›, and how to end; it fades when the pointer rests.
          const strip = el('div', 'kelp-strip');
          const back = el('button', 'kelp-ib', '‹'), next = el('button', 'kelp-ib', '›');
          const where = el('span', 'kelp-where');
          back.onclick = () => { at = Math.max(at - 1, 0); present(); };
          next.onclick = () => { at = Math.min(at + 1, slides.length - 1); present(); };
          strip.append(back, where, next, el('span', 'kelp-sep'), el('span', 'kelp-esc', L.escEnds));
          document.body.append(strip);
          const wake = () => {
            strip.classList.add('on'); clearTimeout(quiet);
            quiet = setTimeout(() => strip.classList.remove('on'), 2000);
          };
          addEventListener('mousemove', () => { if (at >= 0) wake(); });
          function present() {
            slides.forEach((f, i) => f.closest('.frame').classList.toggle('kelp-current', i === at));
            const f = slides[at];
            const fits = f && Math.min(innerWidth / f.offsetWidth, (innerHeight - 64) / f.offsetHeight);
            if (f) f.style.transform = 'scale(' + fits + ')';
            if (f) {
              const name = (f.closest('.frame').querySelector('.name')?.firstChild?.textContent || '').split(' · ')[0];
              where.textContent = name + ' · ' + (at + 1) + ' ' + L.of + ' ' + slides.length;
              wake();
            }
          }
          window.kelpPresent = on => {
            at = on ? 0 : -1;
            document.body.classList.toggle('kelp-present', on);
            if (!on) for (const f of slides) f.style.transform = '';
            present();
          };
          addEventListener('keydown', e => {
            if (at < 0) return;
            if (['ArrowRight', 'ArrowDown', 'PageDown', ' '].includes(e.key)) at = Math.min(at + 1, slides.length - 1);
            else if (['ArrowLeft', 'ArrowUp', 'PageUp'].includes(e.key)) at = Math.max(at - 1, 0);
            else if (e.key === 'Escape') { kelpPresent(false); post({ kind: 'present' }); return; }
            else return;
            e.preventDefault(); present();
          });
          addEventListener('resize', () => { if (at >= 0) present(); });
          addEventListener('resize', draw);
          new ResizeObserver(() => requestAnimationFrame(draw)).observe(document.body);
          draw();
        """

    /// The style of what Kelp puts on the canvas (pins, the column's rows, Pick, tweaks, the strip while presenting).
    static let style = """
        .kelp-layer { position: absolute; inset: 0 auto auto 0; pointer-events: none; z-index: 10; }
        .kelp-sheet { position: fixed; inset: 0; display: none; cursor: crosshair; z-index: 15; }
        .kelp-with-col .kelp-sheet { right: 260px; }
        .kelp-outline { position: absolute; display: none; border: 1.5px solid var(--k-orange); border-radius: 3px; }
        .kelp-pin { position: absolute; width: 18px; height: 18px; border-radius: 50%; background: var(--k-orange);
          color: #1d1d1f; font: 600 10px/18px -apple-system, sans-serif; text-align: center;
          box-shadow: 0 0 0 2px var(--k-card); }
        .kelp-num { width: 16px; height: 16px; border-radius: 50%; background: var(--k-orange); color: #1d1d1f;
          font: 600 10px/16px -apple-system, sans-serif; text-align: center; }
        .kelp-what { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .kelp-indent { padding-left: 36px; padding-top: 0; }
        .kelp-end { justify-content: flex-end; padding-top: 10px; }
        .kelp-field { flex: 1; min-width: 0; height: 22px; box-sizing: border-box; padding: 0 7px; border: 0;
          border-radius: 6px; background: var(--k-card); color: var(--k-label); font: inherit;
          box-shadow: inset 0 0 0 1px var(--k-sep); }
        .kelp-issue { align-items: flex-start; }
        .kelp-mark-warn { width: 14px; height: 14px; border-radius: 4px; color: var(--k-text-orange);
          font: 700 10px/14px -apple-system, sans-serif; text-align: center;
          box-shadow: 0 0 0 1px var(--k-orange); margin-top: 1px; }
        .kelp-pick, .kelp-tweaks { margin-left: 10px; border: 0; border-radius: 999px; padding: 1px 8px; font: inherit;
          font-weight: 500; background: var(--k-rest); color: inherit; opacity: 0; }
        .row h2:hover .kelp-pick, .kelp-tweaks { opacity: 1; }
        .kelp-panel { display: none; gap: 14px; flex-wrap: wrap; padding: 6px 0 4px; font-size: 11px; }
        .kelp-panel.open { display: flex; }
        .kelp-panel label { display: flex; gap: 6px; align-items: center; }
        .kelp-panel input[type=color] { width: 22px; height: 18px; border: 0; padding: 0; background: none; }
        .kelp-tseg { display: inline-flex; border-radius: 999px; background: var(--k-rest); padding: 1px; }
        .kelp-tseg button { border: 0; background: none; color: inherit; font: inherit; padding: 1px 7px;
          border-radius: 999px; }
        .kelp-tseg button.on { background: var(--k-card); box-shadow: 0 .5px 2px rgba(0,0,0,.12); }
        .kelp-strip { position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); z-index: 40; display: none;
          align-items: center; gap: 8px; height: 34px; padding: 0 10px; border-radius: 999px; opacity: 0;
          background: rgba(40,40,40,.85); color: rgba(255,255,255,.85); font: 12px -apple-system, sans-serif;
          transition: opacity .17s ease-in; }
        .kelp-present .kelp-strip { display: flex; }
        .kelp-strip.on { opacity: 1; transition: opacity .12s ease-out; }
        .kelp-strip .kelp-ib { color: inherit; }
        .kelp-strip .kelp-sep { background: rgba(255,255,255,.2); }
        .kelp-where { font-variant-numeric: tabular-nums; }
        .kelp-esc { color: rgba(255,255,255,.6); }
        .kelp-present { overflow: hidden; }
        .kelp-present #kelp-canvas { transform: none !important; }
        .kelp-present .row h2, .kelp-present .name, .kelp-present .kelp-layer,
          .kelp-present .kelp-panel, .kelp-present .frame { display: none !important; }
        .kelp-present .frame.kelp-current { display: flex !important; position: fixed; inset: 0; z-index: 30;
          align-items: center; justify-content: center; background: #000; padding-bottom: 64px;
          box-sizing: border-box; }
        .kelp-present .kelp-current iframe { flex: none; box-shadow: none; border-radius: 0; }
        @media print {
          #kelp-canvas { transform: none !important; }
          .name, .kelp-pick, .kelp-tweaks, .kelp-layer, .kelp-panel, .kelp-col, .kelp-float, .kelp-issues,
            .frame:has(iframe[data-theme="dark"]) { display: none !important; }
          .frame { break-after: page; }
        }
        """
}
