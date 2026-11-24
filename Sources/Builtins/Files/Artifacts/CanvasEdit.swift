import Core
import Foundation

/// Kelp's script for what the user does on a canvas. It runs in `MarkdownTab.world`, and the boards' own scripts don't
/// run. It handles:
/// - Mark's tools (`kelpMark(true)` from the bar): a click marks an element, a drag marks an area or draws a stroke.
/// The marks themselves, their column and the check strip are `MarkColumn`'s; this tells it where a mark is on the
/// boards, and shows a board as it was sent for Before;
/// - the Pick button on each row;
/// - each board's tweaks, which move the board live and are saved;
/// Present is `CanvasPresent`'s. It sends these to `kelpSync`: `pick`, `tweak` and `fixCheck`.
enum CanvasEdit {
    struct Labels: Encodable {
        var pick: String, tweaks: String, check: String, askFix: String, noMarks: String, noIssues: String
        var of: String, escEnds: String, element: String, area: String, pen: String
        var arrow: String, label: String, undo: String, redo: String, whole: String, wholePage: String
    }

    /// `before` holds each board as a mark to check was sent with, by `board@version@theme`, for Before.
    static func source(tweaks: [String: [Tweak]], before: [String: String], labels: Labels) -> String {
        """
        (function () {
          const tweaks = \(MarkdownTab.js(tweaks)), BEFORE = \(MarkdownTab.js(before));
          const L = \(MarkdownTab.js(labels));
        \(body)
        })();
        """
    }

    private static let body = """
          // The column (`CanvasChrome`) is set up before this script, on every canvas.
          const C = window.kelpColumn; if (!C) return;
          const { el, post } = C;
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
            outline.classList.toggle('kelp-outline-edit', m === 'edit');   // orange is Mark's: a mark waits for you
          };
          const pointed = e => e.closest('[data-id]') || e;
          // An element with no data-id is named by its tag and place (`img@3`): the tab writes it one (`stampIDs`).
          const describe = e => {
            const d = e.closest('[data-id]'), t = e.tagName, r = (d || e).getBoundingClientRect();
            return { target: d ? '[data-id=' + d.getAttribute('data-id') + ']' : t.toLowerCase() + '@'
              + [...e.ownerDocument.body.getElementsByTagName(t)].indexOf(e),
              text: (e.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 60),
              area: [r.x, r.y, r.width, r.height].map(Math.round) };
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
          const NS = 'http://www.w3.org/2000/svg', K = window.kelpMarks;
          const last = m => m.rounds[m.rounds.length - 1];
          // A board's frame under a point, and the point in the board's own pixels.
          function frameAt(e) {
            for (const f of frames) {
              const r = f.getBoundingClientRect();
              if (e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom) {
                const k = r.width / f.offsetWidth;
                return { f, k, x: (e.clientX - r.left) / k, y: (e.clientY - r.top) / k };
              }
            }
            return null;
          }
          const inPage = (f, x, y, w, h) => {
            const fr = f.getBoundingClientRect(), k = fr.width / f.offsetWidth;
            return { x: fr.left + scrollX + x * k, y: fr.top + scrollY + y * k, w: w * k, h: h * k };
          };
          const shown = new Map();   // a frame's own page while Before shows the old one
          // Where an element's own content is (its text, its children), not its whole box: a heading or a row spans
          // the board's width, and its mark belongs where its words end.
          function content(f, e) {
            const r = e.ownerDocument.createRange(); r.selectNodeContents(e);
            const c = r.getBoundingClientRect(), whole = box(f, e);
            if (!c.width || !c.height) return whole;
            const fr = f.getBoundingClientRect(), k = fr.width / f.offsetWidth;
            return { x: fr.left + scrollX + c.left * k, y: whole.y, w: c.width * k, h: whole.h };
          }
          const hooks = {
            empty: L.noMarks,
            what: m => m.kind === 'area' && !m.area ? (window.kelpMotion ? L.whole : L.wholePage)
              : m.kind === 'area' && m.text ? L.label + ' «' + m.text + '»' : m.kind === 'area' ? L.area
              : m.kind === 'pen' ? L.pen + (m.target ? ' · ' + m.target : '')
              : m.target + (m.text ? ' «' + m.text + '»' : ''),
            where(m) {
              const motion = window.kelpMotion;   // a mark on a motion page shows near its second only
              if (m.time != null && motion && Math.abs(motion.time() - m.time) > 0.5) return null;
              if (m.kind === 'area' || m.kind === 'pen') {
                const f = light(m.board); if (!f || !m.area) return null;
                const [x, y, w, h] = m.area;   // a label: a point, as wide as its words
                return w || h || !m.text ? inPage(f, ...m.area) : Object.assign(inPage(f, x, y, 0, 0),
                  { w: m.text.length * 7 + 12, h: 18 });
              }
              const at = find(m); return at ? content(at.f, at.e) : null;
            },
            draw(m, into, r) {
              if (m.kind === 'area' && m.text) {
                const t = el('div', 'kelp-label kelp-n-' + m.state, m.text); place(t, r); into.append(t);
              } else if (m.kind === 'area') {
                const a = el('div', 'kelp-area kelp-n-' + m.state); place(a, r); into.append(a);
              }
              if (m.kind !== 'pen' || !m.path) return;
              const f = light(m.board); if (!f) return;
              const fr = inPage(f, 0, 0, f.offsetWidth, f.offsetHeight), svg = document.createElementNS(NS, 'svg');
              svg.setAttribute('class', 'kelp-stroke kelp-n-' + m.state);
              svg.setAttribute('viewBox', '0 0 ' + f.offsetWidth + ' ' + f.offsetHeight);
              place(svg, fr);
              const path = document.createElementNS(NS, 'path');
              path.setAttribute('d', m.path); path.setAttribute('vector-effect', 'non-scaling-stroke');
              svg.append(path); into.append(svg);
            },
            focus(m) {
              if (m.time != null) window.kelpMotion?.seek(m.time);
              const r = hooks.where(m); if (!r) return;
              scrollTo({ left: Math.max(0, r.x - innerWidth / 3), top: Math.max(0, r.y - innerHeight / 3),
                behavior: 'smooth' });
            },
            before: Object.keys(BEFORE).length ? (m, on) => {
              const n = last(m)?.before;
              for (const f of frames.filter(f => f.dataset.board === m.board)) {
                const old = BEFORE[m.board + '@' + n + '@' + f.dataset.theme];
                if (on && old && !shown.has(f)) { shown.set(f, f.srcdoc); f.srcdoc = old; }
                else if (!on && shown.has(f)) { f.srcdoc = shown.get(f); shown.delete(f); }
              }
            } : null,
            tabs: () => [['check', L.check + ' ' + (window.kelpIssues || []).length]],
            tabRows: () => checkRows(window.kelpIssues || [])
          };
          const draw = () => K?.draw();
          // Mark's tools: an element (a click), an area, a stroke or an arrow (a drag), a label (a click, then its
          // words; a double click changes them), each on one board. ↶ ↷ take the last drawn away and put it back.
          // They sit at the bottom: the top's right holds the views (languages, themes), and both don't fit across.
          let tool = 'element', drag = null, undone = [];
          const tools = el('div', 'kelp-float kelp-tools');
          const step = (back) => {
            const m = back ? K.drop() : undone.pop(); if (!m) return;
            if (back) undone.push(m); else K.put(m);
          };
          const drawTools = () => {
            const kinds = [['element', L.element], ['area', L.area], ['pen', L.pen], ['arrow', L.arrow],
              ['label', L.label]];
            const back = el('button', 'kelp-ib', '↶'), again = el('button', 'kelp-ib', '↷');
            back.title = L.undo; again.title = L.redo;
            back.onclick = () => step(true); again.onclick = () => step(false);
            tools.replaceChildren(C.tabs(kinds, tool, k => { tool = k; drawTools(); }), back, again);
          };
          drawTools();
          document.body.append(tools);
          window.kelpMark = on => {
            setMode(on ? 'mark' : mode === 'mark' ? null : mode);
            tools.style.display = on ? 'flex' : 'none';
            K?.setOn(on);
          };
          tools.style.display = 'none';
          K?.attach(hooks);
          function checkRows(issues) {
            if (!issues.length) return [el('p', 'kelp-note', L.noIssues)];
            const rows = issues.map(t => {
              const r = el('div', 'kelp-row kelp-issue');
              const mark = el('span', 'kelp-mark-warn');
              mark.innerHTML = \(CanvasChrome.Glyph.warning.js);
              r.append(mark, el('span', 'kelp-grow', t)); window.kelpIssueFix?.(t, r);
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
            if (drag) return grow(e);
            const at = mode !== 'peek' && !(mode === 'mark' && tool !== 'element') && under(e, mode === 'edit');
            outline.style.display = at ? 'block' : 'none';
            if (at) place(outline, box(at.f, at.e));
          });
          sheet.addEventListener('mousedown', e => {
            if (mode !== 'mark' || tool === 'element' || tool === 'label') return;
            const at = frameAt(e); if (!at) return;
            const shape = tool === 'area' ? el('div', 'kelp-area') : document.createElementNS(NS, 'svg');
            if (tool === 'pen' || tool === 'arrow') {
              shape.setAttribute('class', 'kelp-stroke'); shape.append(document.createElementNS(NS, 'path'));
              shape.setAttribute('viewBox', '0 0 ' + at.f.offsetWidth + ' ' + at.f.offsetHeight);
              place(shape, inPage(at.f, 0, 0, at.f.offsetWidth, at.f.offsetHeight));
            }
            layer.append(shape);
            drag = { ...at, shape, points: [[at.x, at.y]], start: e };
            e.preventDefault();
          });
          function grow(e) {
            const r = drag.f.getBoundingClientRect(), k = drag.k;
            const x = Math.min(Math.max((e.clientX - r.left) / k, 0), drag.f.offsetWidth);
            const y = Math.min(Math.max((e.clientY - r.top) / k, 0), drag.f.offsetHeight);
            drag.points.push([x, y]);
            if (tool === 'arrow') drag.points = [drag.points[0], [x, y]];
            if (tool === 'area') {
              const [x0, y0] = drag.points[0];
              drag.box = [Math.min(x0, x), Math.min(y0, y), Math.abs(x - x0), Math.abs(y - y0)];
              place(drag.shape, inPage(drag.f, ...drag.box));
            } else {
              drag.shape.firstChild.setAttribute('d', tool === 'arrow' ? arrow(drag.points) : path(drag.points));
              drag.shape.firstChild.setAttribute('vector-effect', 'non-scaling-stroke');
            }
          }
          const path = ps => 'M' + ps.map(([x, y]) => Math.round(x) + ' ' + Math.round(y)).join(' L');
          // A line from the first point to the last, with a head of two strokes at the last.
          function arrow([[x0, y0], [x1, y1]]) {
            const a = Math.atan2(y1 - y0, x1 - x0), n = Math.max(12, Math.hypot(x1 - x0, y1 - y0) / 8);
            const head = d => [x1 - n * Math.cos(a + d), y1 - n * Math.sin(a + d)];
            return path([[x0, y0], [x1, y1]]) + ' ' + path([head(0.45), [x1, y1], head(-0.45)]);
          }
          addEventListener('mouseup', e => {
            if (!drag) return;
            const d = drag; drag = null; d.shape.remove();
            const board = d.f.dataset.board;
            if (tool === 'area' && d.box && d.box[2] > 6 && d.box[3] > 6) {
              const near = under({ clientX: e.clientX, clientY: e.clientY });
              K.add({ kind: 'area', board, area: d.box.map(Math.round),
                target: near ? describe(near.e).target : '' });
            } else if ((tool === 'pen' && d.points.length > 2) || (tool === 'arrow' && d.points.length === 2)) {
              const xs = d.points.map(p => p[0]), ys = d.points.map(p => p[1]);
              const x0 = Math.min(...xs), y0 = Math.min(...ys);
              if (tool === 'arrow' && Math.max(...xs) - x0 + Math.max(...ys) - y0 < 8) return;
              const near = under(tool === 'arrow' ? e : d.start);
              K.add({ kind: 'pen', board, path: tool === 'arrow' ? arrow(d.points) : path(d.points),
                target: near ? describe(near.e).target : '',
                area: [x0, y0, Math.max(...xs) - x0, Math.max(...ys) - y0].map(Math.round) });
            }
          });
          // A label's field, at a point of a board: its words become a mark, or mark `m`'s new words.
          function labelField(at, m) {
            const field = el('input', 'kelp-label-field'); field.value = m ? m.text : '';
            const r = inPage(at.f, at.x, at.y, 0, 0);
            Object.assign(field.style, { left: r.x + 'px', top: (r.y - 10) + 'px' });
            document.body.append(field); field.focus();
            let open = true;
            const end = keepIt => {
              if (!open) return;
              open = false; field.remove();
              const text = field.value.trim();
              if (!keepIt || !text) return;
              if (m) { m.text = text; K.changed(); return; }
              const near = under({ clientX: at.cx, clientY: at.cy });
              K.add({ kind: 'area', board: at.f.dataset.board, area: [Math.round(at.x), Math.round(at.y), 0, 0], text,
                target: near ? describe(near.e).target : '' });
            };
            field.addEventListener('keydown', ev => {
              if (ev.key === 'Enter' || ev.key === 'Escape') { ev.preventDefault(); end(ev.key === 'Enter'); }
              ev.stopPropagation();
            });
            field.addEventListener('blur', () => end(true));
          }
          sheet.addEventListener('click', e => {
            if (mode === 'mark' && tool === 'label') {
              const at = frameAt(e); if (!at || e.detail > 1) return;
              return labelField(Object.assign(at, { cx: e.clientX, cy: e.clientY }));
            }
            const at = mode === 'mark' && tool === 'element' && under(e); if (!at) return;
            K.add(Object.assign({ kind: 'element', board: at.f.dataset.board }, describe(at.e)));
          });
          sheet.addEventListener('dblclick', e => {
            if (mode !== 'mark') return;
            const at = frameAt(e); if (!at) return;
            const m = K.list().find(k => k.state === 'draft' && k.kind === 'area' && k.text
              && k.board === at.f.dataset.board && Math.abs(k.area[0] - at.x) < k.text.length * 7 + 12
              && Math.abs(k.area[1] + 9 - at.y) < 14);
            if (m) labelField(Object.assign(at, { x: m.area[0], y: m.area[1] }), m);
          });
          for (const f of frames) f.addEventListener('load', draw);
          // A board's name: its name row's words, not the ring that shows while the agent writes it.
          const nameOf = f => ([...(f.closest('.frame')?.querySelector('.name')?.childNodes || [])]
            .find(n => n.nodeType === 3 && n.textContent.trim())?.textContent || '').split(' · ')[0].trim();
          // An element's data-id, given at its first change by hand when it has none: written into the board at
          // once (`giveID`, found again by its place among the body's elements of its tag), before the change.
          function need(f, e) {
            const had = e.getAttribute('data-id'); if (had) return had;
            const doc = e.ownerDocument, tag = e.tagName.toLowerCase();
            let n = 1; while (doc.querySelector('[data-id="' + tag + '-' + n + '"]')) n++;
            const id = tag + '-' + n, index = [...doc.body.getElementsByTagName(e.tagName)].indexOf(e);
            e.setAttribute('data-id', id);
            post({ kind: 'giveID', board: f.dataset.board, tag, index, id });
            return id;
          }
          window.kelpCanvas = { frames, light, box, place, el, post, sheet, layer, under, setMode, mode: () => mode,
            hooks, find, inPage, describe, need, nameOf, tool: () => tool };
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
          // ⌘Z and ⇧⌘Z take back what was changed by hand on the boards; a field being typed in keeps its own.
          addEventListener('keydown', e => {
            const t = e.target, typing = t.isContentEditable || /^(INPUT|TEXTAREA)$/.test(t.tagName);
            if (!e.metaKey || e.key.toLowerCase() !== 'z' || typing) return;
            e.preventDefault(); post({ kind: 'undo', redo: e.shiftKey });
          });
          addEventListener('resize', draw);
          new ResizeObserver(() => requestAnimationFrame(draw)).observe(document.body);
          draw();
        """
}
