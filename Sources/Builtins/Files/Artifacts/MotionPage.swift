import Core
import Foundation
import Markdown

/// A motion page (`motion.html`) as the tab shows it: a canvas with one board, the stage, so that Mark and Edit work on
/// it as on any board (`CanvasEdit`, `CanvasEditMode`, `MarkColumn`). The page's own scripts don't run: it moves with
/// CSS animations, and Kelp's script (`source`) holds them all on one timeline. It pauses every animation in the
/// stage's frame and sets its time (`seek`), shows each scene (`data-start`, `data-duration`) only in its stretch of
/// time, and plays the timeline in step with the screen. It sends `motion` to `kelpSync` with the time, the length,
/// whether it plays, the scenes and the tracks (each element that moves), a few times a second while playing;
/// `window.kelpMotion` is what the tab's studio (`MotionStudio`) and the export (`MarkdownTab.exportVideo`) call.
enum MotionPage {
    /// The board's name, as marks and hand edits name it.
    static let board = Artifacts.Kind.motion.file

    /// Builds the page for the motion page's `text` in `folder`: the stage at its own size (`data-width` ×
    /// `data-height` on its body) with the design system's tokens, the marks beside it, and the stage as each mark
    /// to check was sent with, for Before. It reads files, so call it off the main thread.
    static func build(_ text: String, folder: URL, root: String) -> CanvasPage.Built {
        let read = { (url: URL) in
            Artifacts.small(url.path, limit: 4 << 20).map { String(decoding: $0, as: UTF8.self) }
        }
        let tokensJSON = read(DesignSystem.dir(root: root).appendingPathComponent("tokens.json")) ?? ""
        let vars = DesignSystem.css(tokens: tokensJSON).light
        let stage = { (page: String) in
            "<base href=\"\(folder.absoluteString)/\"><style>:root { \(vars) }</style>" + page
        }
        let (w, h) = size(text)
        let marks = ArtifactMarks.read(Artifacts.small(folder.appendingPathComponent(ArtifactMarks.file).path))
        var before: [String: String] = [:]
        let file = folder.appendingPathComponent(board).path
        for mark in marks.marks where mark.state == .check {
            guard let n = mark.rounds.last?.before, before["\(board)@\(n)@light"] == nil,
                let old = read(URL(fileURLWithPath: Artifacts.versionPath(target: file, n)))
            else { continue }
            before["\(board)@\(n)@light"] = stage(old)
        }
        let frame = """
            <div class="frame"><iframe sandbox="allow-same-origin" data-board="\(board)" data-theme="light" \
            data-w="\(w)" data-h="\(h)" style="width: \(w)px; height: \(h)px" \
            srcdoc="\(MarkdownHTML.esc(stage(text)))"></iframe></div>
            """
        return CanvasPage.Built(
            html: CanvasPage.shell(body: "<div id=\"kelp-canvas\" class=\"kelp-motion\">\(frame)</div>", motion: true),
            issues: [], marks: marks, before: before, tokens: DesignSystem.names(tokens: tokensJSON))
    }

    /// The stage's size from its body's `data-width` and `data-height` (1920 × 1080 when not said).
    static func size(_ text: String) -> (Int, Int) {
        let body = text.firstMatch(of: /<body[^>]*>/).map { String($0.output) } ?? ""
        let number = { (name: String) -> Int? in
            guard let r = body.range(of: name + #"\s*=\s*"?(\d+)"#, options: .regularExpression) else { return nil }
            return Int(body[r].filter(\.isNumber))
        }
        return (min(max(number("data-width") ?? 1920, 16), 8000), min(max(number("data-height") ?? 1080, 16), 8000))
    }

    /// The script, stepping by frames of `fps`.
    static func source(fps: Double) -> String { "(function (FPS) {\n" + body + "\n})(\(fps));" }

    private static let body = """
          const post = m => webkit.messageHandlers.kelpSync?.postMessage(m);
          const frame = document.querySelector('iframe[data-board]');
          if (!frame) return;
          let doc = null;
          const parts = () => doc ? [...doc.querySelectorAll('[data-start]')] : [];
          const animations = () => doc ? doc.getAnimations() : [];
          const css = e => e.ownerDocument.defaultView.getComputedStyle(e);
          function duration() {
            const said = doc && parseFloat(doc.body?.dataset.duration);
            if (said > 0) return said;
            let end = 0;
            for (const a of animations()) {
              const t = a.effect && a.effect.getComputedTiming();
              if (t && isFinite(t.endTime)) end = Math.max(end, t.endTime / 1000);
            }
            for (const e of parts()) end = Math.max(end, (+e.dataset.start || 0) + (+e.dataset.duration || 0));
            return end || 5;
          }
          // A picture or a video with its own time is a layer of its own, not a scene.
          const media = e => /^(IMG|VIDEO)$/.test(e.tagName);
          const scenes = () => parts().filter(e => !media(e)).map(e => ({ id: e.dataset.id || '',
            title: e.dataset.title || e.dataset.id || '', start: +e.dataset.start || 0,
            duration: +e.dataset.duration || 0 }));
          // Each element that moves, as a track: its name and when its animations run.
          const named = e => e.dataset.title || e.dataset.id
            || (e.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 28) || e.classList[0]
            || e.tagName.toLowerCase();
          function tracks() {
            const by = new Map();
            for (const a of animations()) {
              const e = a.effect && a.effect.target, timing = a.effect && a.effect.getComputedTiming();
              if (!e || !timing || !isFinite(timing.endTime)) continue;
              const start = (timing.delay || 0) / 1000, end = timing.endTime / 1000;
              const track = by.get(e) || { id: e.dataset.id || '', title: named(e), start, end, delays: [],
                lengths: [], hidden: e.dataset.hidden === 'true', e };
              track.start = Math.min(track.start, start); track.end = Math.max(track.end, end);
              track.delays.push(start); track.lengths.push((timing.activeDuration || 0) / 1000);
              // Its first animation's keyframes, where they are and how the stretch after each eases.
              if (!track.keys && a.animationName) {
                const frames = a.effect.getKeyframes();
                track.keys = { name: a.animationName, delay: start, duration: (timing.duration || 0) / 1000,
                  at: frames.map(k => Math.round(k.computedOffset * 1000) / 10), easing: frames.map(k => k.easing) };
              }
              by.set(e, track);
            }
            for (const e of parts().filter(media)) {
              const start = +e.dataset.start || 0;
              by.set(e, { id: e.dataset.id || '', title: named(e), start, end: start + (+e.dataset.duration || 0),
                delays: [], lengths: [], hidden: e.dataset.hidden === 'true', e });
            }
            // As layers: the frontmost first (a higher z-index, then later in the page).
            const all = [...doc.body.querySelectorAll('*')], z = e => parseInt(css(e).zIndex) || 0;
            return [...by.values()].sort((a, b) => z(b.e) - z(a.e) || all.indexOf(b.e) - all.indexOf(a.e))
              .map(({ e, ...track }) => track);
          }
          let t = 0, playing = false, last = 0, told = 0, moving = null, rate = 1, loop = false;
          let range = null;   // the work area, [in, out] in seconds: play and loop keep to it
          function seek(at) {
            t = Math.max(0, Math.min(at, duration()));
            for (const a of animations()) { a.pause(); a.currentTime = t * 1000; }
            for (const e of parts()) {
              const s = +e.dataset.start || 0, d = +e.dataset.duration || Infinity;
              e.style.visibility = t >= s && t < s + d ? '' : 'hidden';
            }
            for (const v of doc ? doc.querySelectorAll('video') : []) {
              v.pause();
              v.currentTime = Math.max(0, t - (+(v.closest('[data-start]')?.dataset.start) || 0));
            }
            dispatchEvent(new CustomEvent('kelp-zoom'));   // what Kelp draws over the stage follows it
          }
          function tell(now) {
            const at = performance.now();
            if (!now && at - told < 120) return;
            told = at;
            moving = moving || tracks();
            const marks = (window.kelpMarks?.list?.() || []).filter(m => m.time != null && m.state !== 'done')
              .map(m => ({ id: m.id, time: m.time, state: m.state }));
            post({ kind: 'motion', t, duration: duration(), playing, scenes: scenes(), tracks: moving, marks, range,
              width: +frame.dataset.w, height: +frame.dataset.h });
          }
          function tick(at) {
            if (!playing) return;
            t += (at - last) / 1000 * rate; last = at;
            const start = range ? range[0] : 0, end = range ? range[1] : duration();
            if (t >= end) { t = loop ? start : end; playing = loop; }
            seek(t); tell(!playing);
            if (playing) requestAnimationFrame(tick);
          }
          // The stage's page, each time it loads (Before swaps in the page as it was): held at the time shown.
          function bind() {
            doc = frame.contentDocument;
            if (!doc || !doc.body) return;
            const hide = doc.createElement('style');   // what's hidden by hand isn't in the page or the video
            hide.textContent = '[data-hidden="true"] { visibility: hidden !important; }';
            doc.head?.append(hide);
            moving = null; seek(t); tell(true);
          }
          frame.addEventListener('load', bind);
          addEventListener('kelp-marks', () => { if (doc) tell(true); });
          if (frame.contentDocument?.readyState === 'complete') bind();
          window.kelpMotion = {
            duration,
            time: () => t,
            seek(at) { playing = false; seek(at); tell(true); },
            pause() { if (playing) { playing = false; tell(true); } },
            toggle() {
              playing = !playing;
              if (playing) {
                const start = range ? range[0] : 0, end = range ? range[1] : duration();
                if (t >= end || t < start) t = start;
                last = performance.now(); requestAnimationFrame(tick);
              }
              tell(true);
            },
            step(frames) { playing = false; seek(t + frames / FPS); tell(true); },
            // Stacks elements `ids`, the frontmost first, by their z-index (made relative when static), as one edit.
            restack(ids) {
              const changes = ids.map((id, i) => {
                const e = doc?.querySelector('[data-id="' + CSS.escape(id) + '"]'); if (!e) return null;
                const props = { 'z-index': String(ids.length - i) };
                if (css(e).position === 'static') props.position = 'relative';
                return { id, props };
              }).filter(Boolean);
              if (changes.length) post({ kind: 'restyle', board: frame.dataset.board, changes });
            },
            // How fast it plays (1 as made), and whether it starts over at the end.
            setRate(r) { rate = r; },
            setFPS(f) { FPS = f; },
            setLoop(on) { loop = on; },
            // The work area: I and O set its in and out at the time shown, ⇧I and ⇧O take it away.
            setRange(r) { range = r && r[1] > r[0] ? r : null; tell(true); },
            // What element `id`'s animated properties are now, for a keyframe made at the time shown.
            values(id) {
              const e = doc?.querySelector('[data-id="' + CSS.escape(id) + '"]'); if (!e) return null;
              const st = css(e), out = {}, names = new Set(['translate', 'opacity']);
              for (const a of e.getAnimations()) for (const k of a.effect.getKeyframes())
                for (const p of Object.keys(k))
                  if (!['offset', 'computedOffset', 'easing', 'composite'].includes(p)) names.add(p);
              for (const p of names) {
                const name = p.replace(/[A-Z]/g, c => '-' + c.toLowerCase()), v = st.getPropertyValue(name);
                if (v && v !== 'none') out[name] = v;
              }
              if (!out.translate) out.translate = '0px 0px';
              return out;
            },
            // The stage on screen, and its own size, for the export's pictures.
            stage() {
              const r = frame.getBoundingClientRect();
              return [r.left, r.top, r.width, r.height, +frame.dataset.w, +frame.dataset.h];
            },
            // Shows the frame at `at` once it is drawn (two frames of the screen later), with nothing of Kelp's over
            // it; `done()` brings that back.
            async frameAt(at) {
              document.body.classList.add('kelp-rec');
              playing = false; seek(at);
              await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
              return t;
            },
            done() { document.body.classList.remove('kelp-rec'); this.matte(null); },
            // The page's background as `colour` for a transparent video's two pictures of a frame (null: its own).
            matte(colour) {
              const id = 'kelp-matte', old = doc?.getElementById(id); old?.remove();
              if (!colour || !doc) return;
              const s = doc.createElement('style'); s.id = id;
              s.textContent = 'html, body { background: ' + colour + ' !important; }';
              doc.head.append(s);
            }
          };
          addEventListener('keydown', e => {
            const typing = e.target.isContentEditable || /^(INPUT|TEXTAREA)$/.test(e.target.tagName);
            if (typing || e.metaKey || e.ctrlKey || e.defaultPrevented) return;
            if (e.key === ' ') window.kelpMotion.toggle();
            else if (e.key.toLowerCase() === 'k' && !e.shiftKey) post({ kind: 'keyframe' });
            else if (e.key.toLowerCase() === 'i' || e.key.toLowerCase() === 'o') {
              const isIn = e.key.toLowerCase() === 'i', r = range || [0, duration()];
              const next = isIn ? [t, Math.max(r[1], t + 0.1)] : [Math.min(r[0], t - 0.1), t];
              window.kelpMotion.setRange(e.shiftKey ? null : next);
            }
            else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
              window.kelpMotion.step((e.key === 'ArrowRight' ? 1 : -1) * (e.shiftKey ? 10 : 1));
            } else return;
            e.preventDefault();
          });
        """

    /// The CSS for a motion page: the stage on black, and nothing of Kelp's over it while recording.
    static let style = """
        body.kelp-motion-page { padding: 24px; background: #000; }
        .kelp-motion .frame { gap: 0; }
        .kelp-motion iframe { border-radius: 0; box-shadow: none; background: #000; }
        .kelp-rec > :not(#kelp-canvas):not(.kelp-col) { visibility: hidden !important; }
        """
}
