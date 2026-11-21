import Core
import Foundation

/// Kelp's script for what the user does on a canvas. It runs in `MarkdownTab.world`, and the boards' own scripts don't
/// run. It handles:
/// - Mark's tools (`kelpMark(true)` from the bar): a click marks an element, a drag marks an area or draws a stroke.
/// The marks themselves, their column and the check strip are `MarkColumn`'s; this tells it where a mark is on the
/// boards, and shows a board as it was sent for Before;
/// - the Pick button on each row;
/// - each board's tweaks, which move the board live and are saved;
/// - Present (`kelpPresent(true)`), which shows the boards one at a time, each as large as the pane. ← → step through
/// them and Esc ends.
/// It sends these to `kelpSync`: `pick`, `tweak`, `fixCheck` and `present` (ended).
enum CanvasEdit {
    struct Labels: Encodable {
        var pick: String, tweaks: String, check: String, askFix: String, noMarks: String, noIssues: String
        var of: String, escEnds: String, element: String, area: String, pen: String
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
            what: m => m.kind === 'area' ? L.area : m.kind === 'pen' ? L.pen + (m.target ? ' · ' + m.target : '')
              : m.target + (m.text ? ' «' + m.text + '»' : ''),
            where(m) {
              if (m.kind === 'area' || m.kind === 'pen') {
                const f = light(m.board); if (!f || !m.area) return null;
                return inPage(f, ...m.area);
              }
              const at = find(m); return at ? content(at.f, at.e) : null;
            },
            draw(m, into, r) {
              if (m.kind === 'area') {
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
          // Mark's tools: an element (a click), an area (a drag) or a stroke (a drag), each on one board.
          let tool = 'element', drag = null;
          const tools = el('div', 'kelp-float kelp-tools');
          const drawTools = () => tools.replaceChildren(C.tabs(
            [['element', L.element], ['area', L.area], ['pen', L.pen]], tool, k => { tool = k; drawTools(); }));
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
            if (drag) return grow(e);
            const at = mode !== 'peek' && !(mode === 'mark' && tool !== 'element') && under(e, mode === 'edit');
            outline.style.display = at ? 'block' : 'none';
            if (at) place(outline, box(at.f, at.e));
          });
          sheet.addEventListener('mousedown', e => {
            if (mode !== 'mark' || tool === 'element') return;
            const at = frameAt(e); if (!at) return;
            const shape = tool === 'area' ? el('div', 'kelp-area') : document.createElementNS(NS, 'svg');
            if (tool === 'pen') {
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
            if (tool === 'area') {
              const [x0, y0] = drag.points[0];
              drag.box = [Math.min(x0, x), Math.min(y0, y), Math.abs(x - x0), Math.abs(y - y0)];
              place(drag.shape, inPage(drag.f, ...drag.box));
            } else {
              drag.shape.firstChild.setAttribute('d', path(drag.points));
              drag.shape.firstChild.setAttribute('vector-effect', 'non-scaling-stroke');
            }
          }
          const path = ps => 'M' + ps.map(([x, y]) => Math.round(x) + ' ' + Math.round(y)).join(' L');
          addEventListener('mouseup', e => {
            if (!drag) return;
            const d = drag; drag = null; d.shape.remove();
            const board = d.f.dataset.board;
            if (tool === 'area' && d.box && d.box[2] > 6 && d.box[3] > 6) {
              const near = under({ clientX: e.clientX, clientY: e.clientY });
              K.add({ kind: 'area', board, area: d.box.map(Math.round),
                target: near ? describe(near.e).target : '' });
            } else if (tool === 'pen' && d.points.length > 2) {
              const xs = d.points.map(p => p[0]), ys = d.points.map(p => p[1]);
              const x0 = Math.min(...xs), y0 = Math.min(...ys);
              const near = under(d.start);
              K.add({ kind: 'pen', board, path: path(d.points), target: near ? describe(near.e).target : '',
                area: [x0, y0, Math.max(...xs) - x0, Math.max(...ys) - y0].map(Math.round) });
            }
          });
          sheet.addEventListener('click', e => {
            const at = mode === 'mark' && tool === 'element' && under(e); if (!at) return;
            K.add(Object.assign({ kind: 'element', board: at.f.dataset.board }, describe(at.e)));
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

    /// The CSS for what Kelp puts on the canvas: pins, the rows in the column, Pick, tweaks, and the strip shown while
    /// presenting.
    static let style = """
        .kelp-tools { top: 10px; left: 50%; transform: translateX(-50%); }
        .kelp-reviewing .kelp-tools { top: 48px; }
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
