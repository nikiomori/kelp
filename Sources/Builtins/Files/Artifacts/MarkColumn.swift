import Core
import Foundation

/// The marks on an agent's page, shared by a canvas (`CanvasEdit`) and a doc or slides (`PageMarks`): the pins, the
/// column on the right (`window.kelpColumn`) and the strip that walks through the marks to check. A mark is a draft
/// (orange: the user's to write and send), with the agent (grey, while its turn runs), the user's to check (orange
/// again, once the turn ends), or done (folded away). The page tells it where a mark is (`kelpMarks.attach`).
///
/// It sends `marksDraft` (the drafts as they are now), `marks` (Send: the drafts to send), `markDone` and `markAgain`
/// to `kelpSync`. The tab answers each with the marks as the daemon wrote them (`kelpMarks.set`).
enum MarkColumn {
    static func source(marks: ArtifactMarks, labels: [String: String]) -> String {
        """
        (function () {
          const C = window.kelpColumn; if (!C) return;
          let M = \(MarkdownTab.js(marks));
          const L = \(MarkdownTab.js(labels));
        \(body)
        })();
        """
    }

    private static let body = """
          const { el, post } = C;
          const layer = el('div', 'kelp-marks'), strip = el('div', 'kelp-review');
          document.body.append(layer, strip);
          let page = null, tab = 'marks', at = 0, doneOpen = false, before = false;
          const by = s => M.marks.filter(m => m.state === s);
          const last = m => m.rounds[m.rounds.length - 1];
          const keep = () => post({ kind: 'marksDraft', marks: by('draft') });
          const typing = () => document.activeElement?.tagName === 'INPUT'
            && !!document.activeElement.closest('.kelp-col');
          const num = m => el('span', 'kelp-num kelp-n-' + m.state, m.state === 'done' ? '✓' : String(m.id || '·'));

          function pins() {
            layer.replaceChildren();
            if (!page) return;
            const current = window.kelpMarks.on ? by('check')[at] : null;
            for (const m of M.marks) {
              if (m.state === 'done') continue;
              const r = page.where(m); if (!r) continue;
              page.draw?.(m, layer, r);
              if (m === current) {
                const box = el('div', 'kelp-current-box');
                Object.assign(box.style, { left: (r.x - 3) + 'px', top: (r.y - 3) + 'px', width: (r.w + 6) + 'px',
                  height: (r.h + 6) + 'px' });
                layer.append(box);
              }
              const pin = el('div', 'kelp-pin kelp-n-' + m.state, String(m.id || '·'));
              Object.assign(pin.style, { left: (r.x + r.w - 9) + 'px', top: (r.y - 9) + 'px' });
              layer.append(pin);
            }
            page.drawn?.();
          }

          function row(m, current) {
            const box = el('div', 'kelp-mark' + (current ? ' kelp-on' : ''));
            const head = el('div', 'kelp-row');
            head.append(num(m), el('span', 'kelp-grow kelp-what', page ? page.what(m) : ''));
            if (m.state === 'draft') {
              const x = el('button', 'kelp-ib', '×'); x.title = L.remove;
              x.onclick = e => { e.stopPropagation(); M.marks = M.marks.filter(k => k !== m); keep(); draw(); };
              head.append(x);
            } else if (m.state === 'sent') {
              head.append(el('span', 'kelp-spin'));
            } else if (m.state === 'done') {
              const again = el('button', 'kelp-ib', '↺'); again.title = L.again;
              again.onclick = e => { e.stopPropagation(); sendAgain(m); };
              head.append(again);
            }
            box.append(head);
            const body = el('div', 'kelp-mark-body');
            const said = last(m);
            for (const r of m.state === 'draft' ? m.rounds : m.rounds.slice(0, -1)) {
              body.append(el('div', 'kelp-past', L.you + ': ' + (r.note || L.look)));
              if (r.reply) body.append(el('div', 'kelp-past', L.agent + ': ' + r.reply));
            }
            if (m.state === 'draft') {
              // By its place among the drafts, which the daemon keeps: the mark itself may be replaced meanwhile.
              const i = by('draft').indexOf(m), note = el('input', 'kelp-field');
              const take = () => { const d = by('draft')[i]; if (d) d.note = note.value; };
              note.placeholder = m.rounds.length ? L.whatsWrong : L.note; note.value = m.note;
              note.addEventListener('change', () => { take(); keep(); });
              note.addEventListener('keydown', e => {
                if (e.key === 'Enter' && e.metaKey) { take(); send(); }
                else if (e.key === 'Enter') note.blur();
              });
              body.append(note);
            } else if (said) {
              body.append(el('div', 'kelp-said' + (m.state === 'done' ? ' kelp-faded' : ''), said.note || L.look));
              if (said.reply) {
                const r = el('div', 'kelp-reply'); r.append(el('b', null, L.agent + ' '), said.reply);
                body.append(r);
              }
              if (m.state === 'check') {
                const how = said.outcome === 'changed' ? L.changedIn + ' ' + (said.after ?? '')
                  : said.outcome === 'gone' ? L.goneIn + ' ' + (said.after ?? '') : L.same;
                body.append(el('div', 'kelp-outcome' + (said.outcome === 'changed' ? '' : ' kelp-warn'), how));
              }
            }
            box.append(body);
            if (m.state === 'check') box.onclick = () => { at = by('check').indexOf(m); show(); };
            return box;
          }

          function edits() {
            return M.edits.map(e => {
              const r = el('div', 'kelp-row kelp-edit');
              const change = e.what === 'text' ? '«' + (e.from ?? '') + '» → «' + (e.to ?? '') + '»'
                : e.what + ' ' + (e.from ?? '—') + ' → ' + (e.to ?? '—');
              r.append(el('span', 'kelp-pen', '✎'), el('span', 'kelp-what-id', e.id),
                el('span', 'kelp-grow kelp-what', change));
              return r;
            });
          }

          function sec(text) { return el('div', 'kelp-sec', text); }

          function rows() {
            const d = by('draft'), s = by('sent'), c = by('check'), done = by('done');
            if (!M.marks.length && !M.edits.length) return [el('p', 'kelp-note', page ? page.empty : '')];
            const out = [];
            if (c.length) {
              out.push(sec(L.toCheck + ' · ' + c.length)); c.forEach((m, i) => out.push(row(m, i === at)));
            }
            if (d.length) { out.push(sec(L.fresh + ' · ' + d.length)); d.forEach(m => out.push(row(m))); }
            if (M.edits.length) { out.push(sec(L.yourEdits + ' · ' + M.edits.length), ...edits()); }
            if (s.length) { out.push(sec(L.withAgent + ' · ' + s.length)); s.forEach(m => out.push(row(m))); }
            if (done.length) {
              const h = sec(L.done + ' · ' + done.length + (doneOpen ? ' ▾' : ' ▸'));
              h.classList.add('kelp-fold'); h.onclick = () => { doneOpen = !doneOpen; draw(); };
              out.push(h);
              if (doneOpen) done.forEach(m => out.push(row(m)));
            }
            if (d.length || M.edits.length) {
              const go = el('button', 'kelp-prominent', L.send), foot = el('div', 'kelp-row kelp-end');
              go.onclick = send;
              foot.append(el('span', 'kelp-grow kelp-hint', '⌘↩'), go);
              out.push(foot);
            }
            return out;
          }

          function column() {
            if (!window.kelpMarks.on) return;
            const open = M.marks.filter(m => m.state !== 'done').length;
            const tabs = [['marks', L.marks + ' ' + open]].concat(page?.tabs?.() ?? []);
            C.open([C.tabs(tabs, tab, key => { tab = key; draw(); })], tab === 'marks' ? rows() : page.tabRows(tab));
          }

          function review() {
            const c = by('check'), on = window.kelpMarks.on && c.length > 0;
            strip.style.display = on ? 'flex' : 'none';
            document.body.classList.toggle('kelp-reviewing', on);
            if (!on) return;
            at = Math.min(at, c.length - 1);
            const back = el('button', 'kelp-ib', '‹'), next = el('button', 'kelp-ib', '›');
            back.onclick = () => step(-1); next.onclick = () => step(1);
            const again = el('button', 'kelp-pill', L.again), done = el('button', 'kelp-prominent', L.markDone);
            again.onclick = () => sendAgain(c[at]); done.onclick = () => finish(c[at]);
            const parts = [el('span', 'kelp-dot'),
              el('span', 'kelp-grow', L.finished + ' · ' + L.toCheck + ': ' + c.length),
              back, el('span', 'kelp-where', (at + 1) + ' ' + L.of + ' ' + c.length), next];
            if (page?.before) {
              parts.push(C.tabs([['before', L.before], ['after', L.after]], before ? 'before' : 'after',
                k => showBefore(k === 'before')), el('span', 'kelp-hint', L.space));
            }
            parts.push(again, done, el('span', 'kelp-hint', '↩'));
            strip.replaceChildren(...parts);
          }

          function draw() { pins(); column(); review(); }

          function show() {
            const m = by('check')[at];
            if (m) page?.focus?.(m);
            draw();
          }
          function step(d) {
            const n = by('check').length; if (!n) return;
            showBefore(false); at = (at + d + n) % n; show();
          }
          function showBefore(on) {
            const m = by('check')[at];
            if (!page?.before || !m || before === on) return;
            before = on; page.before(m, on); review();
          }
          function finish(m) {
            if (!m) return;
            showBefore(false); m.state = 'done'; post({ kind: 'markDone', id: m.id }); show();
          }
          function sendAgain(m) {
            if (!m) return;
            showBefore(false); m.state = 'draft'; m.note = ''; post({ kind: 'markAgain', id: m.id }); draw();
            const inputs = document.querySelectorAll('.kelp-col input'); inputs[0]?.focus();
          }
          function send() {
            for (const i of document.querySelectorAll('.kelp-col input')) i.blur();
            if (!by('draft').length && !M.edits.length) return;
            post({ kind: 'marks', marks: by('draft') });
          }

          addEventListener('keydown', e => {
            if (!window.kelpMarks.on || !by('check').length || typing() || e.metaKey || e.ctrlKey) return;
            if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') step(e.key === 'ArrowRight' ? 1 : -1);
            else if (e.key === 'Enter') (e.shiftKey ? sendAgain : finish)(by('check')[at]);
            else if (e.key === ' ' && !e.repeat) showBefore(true);
            else if (e.key !== ' ') return;
            e.preventDefault();
          });
          addEventListener('keyup', e => { if (e.key === ' ') showBefore(false); });

          window.kelpMarks = {
            on: false,
            attach(hooks) { page = hooks; draw(); },
            setOn(on) {
              this.on = on;
              if (!on) { showBefore(false); C.close(); }
              if (on && by('check').length) show(); else draw();
            },
            add(mark) {
              M.marks.push(Object.assign({ id: 0, kind: 'element', board: '', target: '', text: '', note: '',
                state: 'draft', rounds: [] }, mark));
              tab = 'marks'; keep(); draw();
              const inputs = document.querySelectorAll('.kelp-col input'); inputs[inputs.length - 1]?.focus();
            },
            // The marks as the daemon wrote them. Drafts being typed keep their text; they take the numbers given.
            set(next) {
              if (typing()) {
                const mine = by('draft');
                next.marks.filter(m => m.state === 'draft').forEach((m, i) => { if (mine[i]) m.note = mine[i].note; });
              }
              M = next;
              if (typing()) { pins(); review(); return; }
              draw();
            },
            find: id => M.marks.find(m => m.id === id),
            // Scrolls mark `id` into view and returns its box on screen, with a margin, for its picture.
            reveal(id) {
              const m = M.marks.find(k => k.id === id), r = m && page ? page.where(m) : null;
              if (!r) return null;
              scrollTo(Math.max(0, r.x - innerWidth / 3), Math.max(0, r.y - innerHeight / 3));
              pins();
              const p = 12;
              return [r.x - scrollX - p, r.y - scrollY - p, r.w + 2 * p, r.h + 2 * p];
            },
            draw
          };
          addEventListener('resize', () => requestAnimationFrame(pins));
        """

    static let style = """
        .kelp-marks { position: absolute; inset: 0 auto auto 0; pointer-events: none; z-index: 11; }
        .kelp-pin { position: absolute; width: 18px; height: 18px; border-radius: 50%; background: var(--k-orange);
          color: #1d1d1f; font: 600 10px/18px -apple-system, sans-serif; text-align: center;
          box-shadow: 0 0 0 2px var(--k-card); }
        .kelp-pin.kelp-n-sent { background: var(--k-quiet); color: #fff; }
        .kelp-num.kelp-n-sent { background: var(--k-quiet); color: #fff; }
        .kelp-num.kelp-n-done { background: var(--k-rest); color: var(--k-sec); }
        .kelp-area { position: absolute; border: 1.5px dashed var(--k-orange); border-radius: 4px;
          box-sizing: border-box; }
        .kelp-area.kelp-n-sent { border-color: var(--k-quiet); }
        .kelp-stroke { position: absolute; overflow: visible; }
        .kelp-stroke path { fill: none; stroke: var(--k-orange); stroke-width: 2.5; stroke-linecap: round;
          stroke-linejoin: round; }
        .kelp-stroke.kelp-n-sent path { stroke: var(--k-quiet); }
        .kelp-current-box { position: absolute; border: 1.5px solid var(--k-orange); border-radius: 4px; }
        .kelp-mark { margin: 0 8px; padding: 2px 4px 8px; border-radius: 6px; }
        .kelp-mark .kelp-row { padding: 4px 0; }
        .kelp-mark.kelp-on { background: var(--k-sel); }
        .kelp-mark-body { padding-left: 24px; display: flex; flex-direction: column; gap: 5px; }
        .kelp-past { color: var(--k-sec); font-size: 11px; }
        .kelp-faded { color: var(--k-sec); }
        .kelp-reply { border-radius: 6px; background: var(--k-rest); padding: 6px 8px; }
        .kelp-outcome { color: var(--k-sec); font-size: 11px; }
        .kelp-outcome.kelp-warn { color: var(--k-text-orange); }
        .kelp-spin { width: 10px; height: 10px; border-radius: 50%; border: 1.5px solid var(--k-sep);
          border-top-color: var(--k-sec); animation: kelp-spin 1s linear infinite; flex: none; margin-right: 6px; }
        @keyframes kelp-spin { to { transform: rotate(360deg); } }
        .kelp-edit { padding: 3px 12px 3px 16px; }
        .kelp-pen { width: 16px; text-align: center; color: var(--k-sec); flex: none; }
        .kelp-what-id { color: var(--k-sec); flex: none; }
        .kelp-fold { cursor: default; }
        .kelp-hint { color: var(--k-sec); font-size: 11px; }
        .kelp-review { position: fixed; top: 0; left: 0; right: 0; height: 38px; z-index: 19; display: none;
          align-items: center; gap: 8px; padding: 0 12px; box-sizing: border-box; border-bottom: 1px solid var(--k-sep);
          background: color-mix(in srgb, var(--k-orange) 9%, var(--k-card)); color: var(--k-label);
          font: 12px -apple-system, sans-serif; }
        .kelp-with-col .kelp-review { right: 261px; }
        .kelp-review .kelp-grow { font-weight: 500; }
        .kelp-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--k-orange); flex: none; }
        .kelp-reviewing { padding-top: 70px; }
        .kelp-reviewing .kelp-themes { top: 48px; }
        .kelp-present .kelp-review, .kelp-present .kelp-marks { display: none !important; }
        @media print { .kelp-marks, .kelp-review { display: none !important; } }
        """
}
