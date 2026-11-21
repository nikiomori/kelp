import Foundation

/// Kelp's script for a motion page (`motion.html`). The page's own scripts don't run: it moves with CSS animations,
/// and this script holds them all on one timeline. It pauses every animation and sets its time (`seek`), shows each
/// scene (`data-start`, `data-duration`) only in its stretch of time, plays the timeline in step with the screen, and
/// fits the stage (the body, `data-width` × `data-height`) into the pane. It sends `motion` to `kelpSync` with the
/// time, the length, whether it plays and the scenes, a few times a second while playing; `window.kelpMotion` is what
/// the tab's bar (`MotionBar`) and the export (`MarkdownTab.exportVideo`) call.
enum MotionPage {
    static let source = """
        (function () {
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
          let t = 0, playing = false, last = 0, told = 0;
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
            post({ kind: 'motion', t, duration: duration(), playing, scenes });
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
          window.kelpMotion = {
            duration,
            seek(at) { playing = false; seek(at); tell(true); },
            toggle() {
              playing = !playing;
              if (playing) { if (t >= duration()) t = 0; last = performance.now(); requestAnimationFrame(frame); }
              tell(true);
            },
            step(frames) { playing = false; seek(t + frames / 30); tell(true); },
            // The stage on screen, and its own size, for the export's pictures.
            stage() { const r = body.getBoundingClientRect(); return [r.left, r.top, r.width, r.height, W, H]; },
            // Shows the frame at `at` once it is drawn (two frames of the screen later).
            async frameAt(at) {
              playing = false; seek(at);
              await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
              return t;
            }
          };
          addEventListener('keydown', e => {
            if (e.metaKey || e.ctrlKey) return;
            if (e.key === ' ') window.kelpMotion.toggle();
            else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
              window.kelpMotion.step((e.key === 'ArrowRight' ? 1 : -1) * (e.shiftKey ? 10 : 1));
            } else return;
            e.preventDefault();
          });
          seek(0); tell(true);
        })();
        """
}
