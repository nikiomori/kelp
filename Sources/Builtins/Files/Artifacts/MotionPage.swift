import Foundation

/// Kelp's script for a motion page (`motion.html`). The page's own scripts don't run: it moves with CSS animations,
/// and this script holds them all on one timeline. It pauses every animation and sets its time (`seek`), shows each
/// scene (`data-start`, `data-duration`) only in its stretch of time, plays the timeline in step with the screen, and
/// fits the stage (the body, `data-width` × `data-height`) into the pane. It sends `motion` to `kelpSync` with the
/// time, the length, whether it plays, the scenes and the tracks (each element that moves), a few times a second while
/// playing; `window.kelpMotion` is what the tab's studio (`MotionStudio`) and the export (`MarkdownTab.exportVideo`)
/// call.
enum MotionPage {
    /// The script, stepping by frames of `fps`.
    static func source(fps: Double) -> String { "(function (FPS) {\n" + body + "\n})(\(fps));" }

    private static let body = """
          const post = m => webkit.messageHandlers.kelpSync?.postMessage(m);
          const html = document.documentElement, body = document.body;
          if (!body) return;
          const W = +body.dataset.width || 1920, H = +body.dataset.height || 1080;
          const parts = () => [...document.querySelectorAll('[data-start]')];
          function duration() {
            const said = parseFloat(body.dataset.duration);
            if (said > 0) return said;
            let end = 0;
            for (const a of document.getAnimations()) {
              const t = a.effect && a.effect.getComputedTiming();
              if (t && isFinite(t.endTime)) end = Math.max(end, t.endTime / 1000);
            }
            for (const e of parts()) end = Math.max(end, (+e.dataset.start || 0) + (+e.dataset.duration || 0));
            return end || 5;
          }
          const scenes = parts().map(e => ({ id: e.dataset.id || '', title: e.dataset.title || e.dataset.id || '',
            start: +e.dataset.start || 0, duration: +e.dataset.duration || 0 }));
          // Each element that moves, as a track: its name and when its animations run.
          const named = e => e.dataset.title || e.dataset.id
            || (e.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 28) || e.classList[0]
            || e.tagName.toLowerCase();
          function tracks() {
            const by = new Map();
            for (const a of document.getAnimations()) {
              const e = a.effect && a.effect.target, timing = a.effect && a.effect.getComputedTiming();
              if (!e || !timing || !isFinite(timing.endTime)) continue;
              const start = (timing.delay || 0) / 1000, end = timing.endTime / 1000;
              const track = by.get(e)
                || { id: e.dataset.id || '', title: named(e), start, end, delays: [], lengths: [] };
              track.start = Math.min(track.start, start); track.end = Math.max(track.end, end);
              track.delays.push(start); track.lengths.push((timing.activeDuration || 0) / 1000);
              by.set(e, track);
            }
            return [...by.values()].sort((a, b) => a.start - b.start);
          }
          let t = 0, playing = false, last = 0, told = 0, moving = null;
          function seek(at) {
            t = Math.max(0, Math.min(at, duration()));
            for (const a of document.getAnimations()) { a.pause(); a.currentTime = t * 1000; }
            for (const e of parts()) {
              const s = +e.dataset.start || 0, d = +e.dataset.duration || Infinity;
              e.style.visibility = t >= s && t < s + d ? '' : 'hidden';
            }
            for (const v of document.querySelectorAll('video')) {
              v.pause();
              v.currentTime = Math.max(0, t - (+(v.closest('[data-start]')?.dataset.start) || 0));
            }
          }
          function tell(now) {
            const at = performance.now();
            if (!now && at - told < 120) return;
            told = at;
            moving = moving || tracks();
            post({ kind: 'motion', t, duration: duration(), playing, scenes, tracks: moving, width: W, height: H });
          }
          function frame(at) {
            if (!playing) return;
            t += (at - last) / 1000; last = at;
            if (t >= duration()) { t = duration(); playing = false; }
            seek(t); tell(!playing);
            if (playing) requestAnimationFrame(frame);
          }
          // The stage, as large as the pane allows, in the middle, on black.
          function fit() {
            const k = Math.min(innerWidth / W, innerHeight / H);
            body.style.transform = 'translate(' + (innerWidth - W * k) / 2 + 'px, ' + (innerHeight - H * k) / 2
              + 'px) scale(' + k + ')';
          }
          Object.assign(html.style, { background: '#000', overflow: 'hidden', height: '100%' });
          Object.assign(body.style, { margin: '0', width: W + 'px', height: H + 'px', transformOrigin: '0 0',
            position: 'absolute', left: '0', top: '0' });
          addEventListener('resize', fit);
          fit();
          // The stage takes edits: a click chooses an element (with a data-id), a drag moves it (its `translate`),
          // a double click on an element of text alone lets the user type over it. Each goes to the tab to write.
          let chosen = null, grab = null;
          const pick = e => e && e !== body && body.contains(e) ? e.closest('[data-id]') : null;
          function choose(e, tellTab) {
            if (chosen) chosen.style.outline = '';
            chosen = e;
            if (chosen) Object.assign(chosen.style, { outline: '4px solid #0a84ff', outlineOffset: '6px' });
            if (tellTab) post({ kind: 'motionChose', id: chosen ? chosen.dataset.id : '' });
          }
          const stagePoint = e => { const r = body.getBoundingClientRect(); return [(e.clientX - r.left) * W / r.width,
            (e.clientY - r.top) * H / r.height]; };
          const moved = e => (getComputedStyle(e).translate.match(/-?[\\d.]+/g) || ['0', '0']).map(Number)
            .concat([0]).slice(0, 2);
          addEventListener('mousedown', ev => {
            if (ev.detail > 1 || ev.target.isContentEditable) return;
            if (playing) { playing = false; tell(true); }   // a drag sets the frame it was let go on
            const e = pick(ev.target);
            choose(e, true);
            if (e) { grab = { e, from: stagePoint(ev), was: moved(e), still: true }; ev.preventDefault(); }
          });
          addEventListener('mousemove', ev => {
            if (!grab) return;
            const [x, y] = stagePoint(ev), dx = x - grab.from[0], dy = y - grab.from[1];
            if (grab.still && Math.hypot(dx, dy) < 4) return;
            grab.still = false;
            grab.e.style.translate = Math.round(grab.was[0] + dx) + 'px ' + Math.round(grab.was[1] + dy) + 'px';
          });
          addEventListener('mouseup', () => {
            if (grab && !grab.still) {
              post({ kind: 'motionMove', id: grab.e.dataset.id, translate: grab.e.style.translate });
            }
            grab = null;
          });
          addEventListener('dblclick', ev => {
            const e = pick(ev.target);
            if (!e || e.children.length) return;
            const old = e.textContent;
            e.contentEditable = 'true'; e.focus();
            getSelection().selectAllChildren(e);
            const done = keep => {
              e.contentEditable = 'false';
              if (!keep) { e.textContent = old; return; }
              const text = e.textContent.trim();
              if (text && text !== old.trim()) post({ kind: 'motionText', id: e.dataset.id, old: old.trim(), text });
            };
            e.addEventListener('keydown', k => {
              if (k.key !== 'Enter' && k.key !== 'Escape') return;
              k.preventDefault(); k.stopPropagation(); done(k.key === 'Enter'); e.blur();
            });
            e.addEventListener('blur', () => { if (e.isContentEditable) done(true); }, { once: true });
          });
          window.kelpMotion = {
            duration,
            seek(at) { playing = false; seek(at); tell(true); },
            toggle() {
              playing = !playing;
              if (playing) { if (t >= duration()) t = 0; last = performance.now(); requestAnimationFrame(frame); }
              tell(true);
            },
            step(frames) { playing = false; seek(t + frames / FPS); tell(true); },
            // The stage on screen, and its own size, for the export's pictures.
            stage() { const r = body.getBoundingClientRect(); return [r.left, r.top, r.width, r.height, W, H]; },
            // Shows the frame at `at` once it is drawn (two frames of the screen later).
            choose(id) { choose(id ? document.querySelector('[data-id="' + CSS.escape(id) + '"]') : null, false); },
            async frameAt(at) {
              if (chosen) choose(null, true);   // the outline isn't part of the video
              playing = false; seek(at);
              await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
              return t;
            }
          };
          addEventListener('keydown', e => {
            if (e.target.isContentEditable) return;
            if (e.metaKey && e.key.toLowerCase() === 'z') {
              e.preventDefault(); post({ kind: 'undo', redo: e.shiftKey });
            }
            if (e.metaKey || e.ctrlKey) return;
            if (e.key === ' ') window.kelpMotion.toggle();
            else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
              window.kelpMotion.step((e.key === 'ArrowRight' ? 1 : -1) * (e.shiftKey ? 10 : 1));
            } else return;
            e.preventDefault();
          });
          seek(0); tell(true);
        """
}
