import Core
import Foundation

/// The marks on an agent's page, shared by a canvas (`CanvasEdit`) and a doc or slides (`PageMarks`): the pins, the
/// column on the right (`window.kelpColumn`) and the walk through the marks to check, which the tab's bar shows
/// (`MarkReviewBar`). A mark is a draft
/// (orange: the user's to write and send), with the agent (grey, while its turn runs), the user's to check (orange
/// again, once the turn ends), or done (folded away). The page tells it where a mark is (`kelpMarks.attach`).
///
/// It sends `marksDraft` (the drafts as they are now), `marks` (Send: the drafts to send), `markDone`, `markAgain` and
/// `review` (where the check is) to `kelpSync`. The tab answers each with the marks as the daemon wrote them
/// (`kelpMarks.set`).
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
          const layer = el('div', 'kelp-marks'), composer = el('div', 'kelp-composer');
          document.body.append(layer, composer);
          composer.style.display = 'none';
          let page = null, tab = 'marks', at = 0, before = false, filter = 'waiting';
          // The agent at work, with how many wait for it.
          let busy = { who: '', queued: 0 };
          const by = s => M.marks.filter(m => m.state === s);
          const last = m => m.rounds[m.rounds.length - 1];
          // With the newest mark seen: a draft the agent added since (a question) isn't one removed.
          const seen = () => Math.max(0, ...M.marks.map(m => m.id));
          const keep = () => post({ kind: 'marksDraft', marks: by('draft'), seen: seen() });
          const typing = () => ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName)
            && !!document.activeElement.closest('.kelp-col, .kelp-composer');
          const num = m => m.asked && m.state === 'draft' ? el('span', 'kelp-num kelp-n-ask', '?')
            : m.state === 'done' ? el('span', 'kelp-num kelp-n-done kelp-sym-checkmark')
            : el('span', 'kelp-num kelp-n-' + m.state, String(m.id || '·'));

          function pins() {
            layer.replaceChildren();
            if (!page) return;
            const current = by('check')[at];
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
              const asking = m.asked && m.state === 'draft';
              const pin = el('div', 'kelp-pin kelp-n-' + (asking ? 'ask' : m.state),
                asking ? '?' : String(m.id || '·'));
              Object.assign(pin.style, { left: (r.x + r.w - 9) + 'px', top: (r.y - 9) + 'px' });
              layer.append(pin);
            }
            page.drawn?.();
          }

          function row(m, current) {
            const box = el('div', 'kelp-mark' + (current ? ' kelp-on' : ''));
            const head = el('div', 'kelp-row');
            if (m.state === 'draft') head.append(grip(m, box));
            const what = page ? page.what(m) : '';
            const who = m.asked ? L.asks.replace('%@', L.agent) + ' · ' : '';
            head.append(num(m), el('span', 'kelp-grow kelp-what', who + what));
            const where = m.state !== 'done' && page?.status?.(m);   // its element: moved, gone, or (nothing) in place
            if (where) head.append(page.statusChip(m, where));
            if (m.state === 'draft') {
              const x = el('button', 'kelp-ib'); x.append(el('span', 'kelp-sym-xmark')); x.title = L.remove;
              x.onclick = e => { e.stopPropagation(); M.marks = M.marks.filter(k => k !== m); keep(); draw(); };
              head.append(x);
            } else if (m.state === 'sent') {
              head.append(el('span', 'kelp-spin'));
            } else if (m.state === 'done') {
              const again = el('button', 'kelp-ib'); again.title = L.again;
              again.append(el('span', 'kelp-sym-arrow-uturn-backward'));
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
            if (m.asked && m.state === 'draft') {
              // The agent's choices (`kelp artifact ask … --choice`), one line each: a click answers and sends.
              const [question, ...choices] = m.asked.split('\\n• ');
              body.append(el('div', 'kelp-said', question));
              const row = el('div', 'kelp-row kelp-choices');
              for (const c of choices) {
                const b = el('button', 'kelp-pill', c);
                b.onclick = () => { const d = by('draft').find(d => d.id === m.id); if (d) d.note = c; keep(); send(); };
                row.append(b);
              }
              if (choices.length) body.append(row);
            }
            if (m.state === 'draft') {
              // By its place among the drafts, which the daemon keeps: the mark itself may be replaced meanwhile.
              const i = by('draft').indexOf(m), note = el('input', 'kelp-field');
              const take = () => { const d = by('draft')[i]; if (d) d.note = note.value; };
              note.placeholder = m.asked ? L.answer : m.rounds.length ? L.whatsWrong : L.note; note.value = m.note;
              note.addEventListener('change', () => { take(); keep(); });
              takesPictures(note, m);
              note.addEventListener('keydown', e => {
                if (e.key === 'Enter' && e.metaKey) { take(); send(); }
                else if (e.key === 'Enter') note.blur();
              });
              body.append(note);
              // About every element like this one (its class), not only it.
              const like = m.kind === 'element' && page?.likeOf?.(m);
              if (like) {
                const box = el('label', 'kelp-like'), check = el('input');
                check.type = 'checkbox'; check.checked = !!m.like;
                check.onchange = () => {
                  const d = by('draft')[i]; if (d) d.like = check.checked ? '.' + like.cls : null; keep();
                };
                box.append(check, L.allLike + ' · .' + like.cls + ' ×' + like.count);
                body.append(box);
              }
              if (m.reference) body.append(example(m));
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
            else box.onclick = e => { if (e.target.tagName !== 'INPUT') page?.focus?.(m); };
            return box;
          }

          // A value as people read it: a colour as its swatch and hex, nothing as a dash.
          function shown(v) {
            if (v == null || v === '') return '—';
            const rgb = String(v).match(/^rgba?\\(([^)]+)\\)/), hex = rgb
              ? '#' + rgb[1].split(/[ ,\\/]+/).slice(0, 3).map(n => (+n).toString(16).padStart(2, '0')).join('') : null;
            if (!hex && !/^#[0-9a-f]{3,8}$/i.test(v)) return String(v);
            const out = el('span', 'kelp-value'), swatch = el('span', 'kelp-edit-swatch');
            swatch.style.background = v;
            out.append(swatch, hex || v);
            return out;
          }

          function edits() {
            return M.edits.map(e => {
              const r = el('div', 'kelp-row kelp-edit');
              const change = el('span', 'kelp-grow kelp-what');
              if (e.what === 'text') change.textContent = '«' + (e.from ?? '') + '» → «' + (e.to ?? '') + '»';
              else change.append(e.what + ' ', shown(e.from), ' → ', shown(e.to));
              r.append(el('span', 'kelp-pen kelp-sym-pencil'), el('span', 'kelp-what-id', e.id), change);
              return r;
            });
          }

          function sec(text) { return el('div', 'kelp-sec', text); }

          // A picture pasted or dropped into a mark's note is its example, kept beside the marks as marks/N-ref.png.
          function takesPictures(field, m) {
            const take = files => {
              const file = [...files].find(f => f.type.startsWith('image/'));
              if (!file || !m.id) return false;
              const r = new FileReader();
              r.onload = () => post({ kind: 'markRef', id: m.id, data: String(r.result).split(',')[1] || '' });
              r.readAsDataURL(file);
              return true;
            };
            field.addEventListener('paste', e => { if (take(e.clipboardData?.files || [])) e.preventDefault(); });
            field.addEventListener('dragover', e => e.preventDefault());
            field.addEventListener('drop', e => { if (take(e.dataTransfer?.files || [])) e.preventDefault(); });
          }
          function example(m) {
            const row = el('div', 'kelp-example'), img = el('img');
            img.src = m.reference + '?' + (m.rounds.length);
            row.append(img, el('span', 'kelp-hint', m.reference.split('/').pop()));
            return row;
          }

        \(helpers)
          function rows() {
            const d = by('draft'), s = by('sent'), c = by('check'), done = by('done');
            if (!M.marks.length && !M.edits.length && !M.suggestions?.length) {
              return [el('p', 'kelp-note', page ? page.empty : '')];
            }
            if (filter === 'done') return done.length ? done.map(m => row(m)) : [el('p', 'kelp-note', L.noneDone)];
            const out = [];
            if (c.length) {
              out.push(sec(L.toCheck + ' · ' + c.length)); c.forEach((m, i) => out.push(row(m, i === at)));
            }
            if (d.length) { out.push(sec(L.fresh + ' · ' + d.length)); d.forEach(m => out.push(row(m))); }
            if (M.edits.length) { out.push(sec(L.yourEdits + ' · ' + M.edits.length), ...edits()); }
            if (s.length) { out.push(sec(L.withAgent + ' · ' + s.length)); s.forEach(m => out.push(row(m))); }
            // Done ones show under Done or All: Waiting is what's left to do.
            if (done.length && filter === 'all') {
              out.push(sec(L.done + ' · ' + done.length)); done.forEach(m => out.push(row(m)));
            }
            // What the agent suggests asking next: a click makes it a mark on the whole page, its note to edit.
            if (M.suggestions?.length) {
              out.push(sec(L.next));
              for (const line of M.suggestions) {
                const b = el('button', 'kelp-suggest', line);
                b.onclick = () => {
                  M.suggestions = M.suggestions.filter(s => s !== line);
                  window.kelpMarks.add({ kind: 'area', whole: true, note: line });
                };
                out.push(b);
              }
            }
            if (d.length || M.edits.length) {
              const n = d.length, foot = el('div', 'kelp-row kelp-end');
              const button = (text, prominent, run) => {
                const b = el('button', prominent ? 'kelp-prominent' : 'kelp-pill', text); b.onclick = run; return b;
              };
              foot.append(el('span', 'kelp-grow'));
              // While the agent works: they wait for its turn to end, or go now as a message typed into it.
              if (busy.who) {
                foot.append(button(L.queue, false, () => send(true)), button(L.sendNow, true, () => send()));
              }
              else foot.append(button(d.length ? L.sendCount.replace('%d', n) : L.send, true, () => send()));
              out.push(foot);
            }
            return out;
          }

          function column() {
            if (!window.kelpMarks.on) return;
            const open = M.marks.filter(m => m.state !== 'done').length, more = page?.tabs?.() ?? [];
            // Which marks show: those waiting (to write, with the agent, to check), the done ones, or all.
            const which = C.tabs([['waiting', L.waiting + (open ? ' ' + open : '')], ['done', L.done], ['all', L.all]],
              filter, key => { filter = key; draw(); });
            const queued = busy.queued ? ' · ' + L.queued.replace('%d', busy.queued) : '';
            // Stop: Esc to the agent at work; what it was sent comes back to check at its turn's end.
            const stop = el('button', 'kelp-pill', L.stop);
            stop.onclick = () => post({ kind: 'stopAgent' });
            const band = busy.who
              ? [el('span', 'kelp-busy-dot'), el('span', 'kelp-grow', L.working.replace('%@', busy.who) + queued), stop]
              : [];
            if (!more.length) return C.open([which], rows(), band);
            const tabs = C.tabs([['marks', L.marks]].concat(more), tab, key => { tab = key; draw(); });
            C.open([tabs], tab === 'marks' ? [which, ...rows()] : page.tabRows(tab), band);
          }

          // The tab's bar for the check (`MarkReviewBar`) shows where it is; its buttons call back in here.
          let told = '';
          function review() {
            const c = by('check');
            at = Math.max(0, Math.min(at, c.length - 1));
            const r = c[at] && last(c[at]);   // what was asked of the mark shown, and the agent's answer
            const now = JSON.stringify({ kind: 'review', count: c.length, at, before, canBefore: !!page?.before,
              note: r?.note || '', reply: r?.reply || '' });
            if (now !== told) { told = now; post(JSON.parse(now)); }
          }

          function draw() { pins(); column(); review(); dispatchEvent(new CustomEvent('kelp-marks')); }

          // Where a new mark's note is written: beside the mark. Return keeps it, ⌘Return sends the marks, Esc takes
          // the mark away. The draft is found by its place among the drafts, which the daemon keeps.
          function compose(m) {
            const r = page?.where(m), i = by('draft').indexOf(m);
            if (i >= 0 && !r) return document.querySelectorAll('.kelp-col .kelp-mark input')[i]?.focus();
            if (!r || i < 0) return;
            const field = el('textarea', 'kelp-compose-field');
            field.placeholder = m.rounds.length ? L.whatsWrong : L.note; field.value = m.note; field.rows = 2;
            composer.replaceChildren(field, el('div', 'kelp-hint', L.composeHint));
            const right = scrollX + innerWidth - (document.body.classList.contains('kelp-with-col') ? 280 : 20);
            const left = Math.max(scrollX + 8, Math.min(r.x, right - 290));
            Object.assign(composer.style, { display: 'block', left: left + 'px', top: (r.y + r.h + 10) + 'px' });
            let open = true;
            const done = (keepIt, andSend) => {
              if (!open) return;
              open = false; composer.style.display = 'none';
              const d = by('draft')[i] || m;
              // Esc takes a new mark away; one with rounds stays, a draft again.
              if (keepIt || d.rounds.length) d.note = field.value.trim(); else M.marks = M.marks.filter(k => k !== d);
              keep(); draw();
              if (andSend) send();
            };
            field.addEventListener('keydown', e => {
              if (e.key === 'Escape') { e.preventDefault(); done(false); }
              else if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); done(true, e.metaKey); }
              e.stopPropagation();
            });
            field.addEventListener('blur', () => done(true));
            takesPictures(field, m);
            field.focus();
          }

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
            compose(m);   // what's still wrong, written beside this mark
          }
          // Sends the drafts, in their order, now or once the agent's turn ends (`queue`). One not to send is taken
          // away (×).
          function send(queue) {
            for (const i of document.querySelectorAll('.kelp-col input')) i.blur();
            const d = by('draft');
            if (!d.length && !M.edits.length) return;
            post({ kind: 'marks', marks: d, queue: !!queue, seen: seen() });
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
              // Leaving Mark for Edit keeps the column: Edit's inspector is in it.
              if (!on) { showBefore(false); if (window.kelpCanvas?.mode() !== 'edit') C.close(); }
              if (on && by('check').length) show(); else draw();
            },
            add(mark) {
              // On a motion page, the second it was made at: its pin shows near that second only. A mark on the
              // whole video has none.
              const whole = mark.whole; delete mark.whole;
              if (window.kelpMotion && !whole) mark.time = Math.round(window.kelpMotion.time() * 100) / 100;
              M.marks.push(Object.assign({ id: 0, kind: 'element', board: '', target: '', text: '', note: '',
                state: 'draft', rounds: [] }, mark));
              tab = 'marks'; keep(); draw();
              compose(M.marks[M.marks.length - 1]);
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
            // The newest draft taken away (↶), returned to be put back (`put`, ↷); a draft's words changed.
            drop() {
              const m = by('draft').pop(); if (!m) return null;
              M.marks = M.marks.filter(k => k !== m); keep(); draw(); return m;
            },
            put(m) { M.marks.push(m); keep(); draw(); },
            changed() { keep(); draw(); },
            busy(who, queued) { busy = { who, queued }; draw(); },
            find: id => M.marks.find(m => m.id === id),
            list: () => M.marks,
            step, showBefore,
            openTab(key) { tab = key; draw(); },
            finish: () => finish(by('check')[at]),
            again: () => sendAgain(by('check')[at]),
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
          let moved = false;   // the boards zoomed, or a motion page's time moved: the pins follow, once a frame
          addEventListener('kelp-zoom', () => {
            if (moved) return;
            moved = true; requestAnimationFrame(() => { moved = false; pins(); });
          });
        """
}
