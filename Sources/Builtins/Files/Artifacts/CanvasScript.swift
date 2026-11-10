import Foundation

/// Kelp's script beside a canvas (`MarkdownTab.world`; the boards' own don't run): makes each board's frame as tall as
/// what it holds (unless the board's height is fixed), fits the canvas to the pane, and checks what's drawn: text cut
/// off, contrast under 4.5:1, a board wider or taller than its frame, an image that doesn't load, controls without a
/// `data-id`. The result goes to `kelpSync` as `{kind: "check", issues}`, after the files' own (`CanvasPage.lint`).
enum CanvasScript {
    static func source(issues: [String]) -> String {
        let known = "[" + issues.map(MarkdownTab.jsString).joined(separator: ", ") + "]"
        return """
            (function () {
              const known = \(known);
              const frames = [...document.querySelectorAll('iframe[data-board]')];
              const canvas = document.getElementById('kelp-canvas');
              // Fits the rows to the pane, down to half size (then it scrolls; pinch zooms); labels stay readable.
              function fit() {
                if (!canvas) return;
                canvas.style.transform = '';
                const wide = canvas.scrollWidth + 80;
                const z = Math.max(0.5, Math.min(1, document.documentElement.clientWidth / wide));
                canvas.style.setProperty('--z', z);
                canvas.style.transform = z < 1 ? 'scale(' + z + ')' : '';
                document.body.style.height = z < 1 ? (canvas.scrollHeight * z + 112) + 'px' : '';
                document.body.style.width = z < 1 ? (canvas.scrollWidth * z + 80) + 'px' : '';
              }
              addEventListener('resize', fit);
              new ResizeObserver(() => requestAnimationFrame(fit)).observe(document.documentElement);
              function rgb(s) {
                const m = s.match(/rgba?\\(([^)]+)\\)/); if (!m) return null;
                const p = m[1].split(/[ ,\\/]+/).filter(Boolean).map(Number);
                return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
              }
              function lum(c) {
                const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
                return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
              }
              function ground(win, el, page) {
                for (; el; el = el.parentElement) {
                  const c = rgb(win.getComputedStyle(el).backgroundColor);
                  if (c && c[3] > 0.5) return c;
                }
                return page;
              }
              function named(el) {
                const d = el.closest('[data-id]');
                if (d) return '[data-id=' + d.getAttribute('data-id') + ']';
                const t = (el.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 32);
                return el.tagName.toLowerCase() + (t ? ' «' + t + '»' : '');
              }
              function check(f, out) {
                const doc = f.contentDocument, win = doc && doc.defaultView;
                if (!doc || !doc.body) return;
                const say = t => out.push(f.dataset.board + (f.dataset.theme === 'dark' ? ' (dark)' : '') + ': ' + t);
                const root = doc.documentElement, w = +f.dataset.w, h = +(f.dataset.h || 0);
                if (!h) f.style.height = Math.max(60, Math.ceil(doc.body.getBoundingClientRect().height)) + 'px';
                else if (root.scrollHeight > h + 1) say('content is ' + root.scrollHeight + 'px tall, the frame ' + h);
                if (root.scrollWidth > w + 1) say('content is ' + root.scrollWidth + 'px wide, the board ' + w);
                const page = rgb(win.getComputedStyle(doc.body).backgroundColor) || [255, 255, 255, 1];
                let bare = 0;
                for (const el of doc.body.querySelectorAll('*')) {
                  const st = win.getComputedStyle(el);
                  if (st.display === 'none' || st.visibility === 'hidden') continue;
                  if (['hidden', 'clip'].includes(st.overflowX) && el.scrollWidth > el.clientWidth + 1
                      && (el.textContent || '').trim()) say('text is cut off in ' + named(el));
                  if (el.tagName === 'IMG' && el.complete && !el.naturalWidth)
                    say('image does not load: ' + el.getAttribute('src'));
                  const control = 'button, a[href], input, select, textarea, h1, h2, h3';
                  if (el.matches(control) && !el.closest('[data-id]')) bare++;
                  const text = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
                  const fg = text && +st.opacity > 0 && rgb(st.color);
                  if (!fg) continue;
                  const a = lum(fg), b = lum(ground(win, el, page));
                  const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
                  const size = parseFloat(st.fontSize), big = size >= 24 || (size >= 18.6 && +st.fontWeight >= 700);
                  if (ratio < (big ? 3 : 4.5)) say('contrast ' + ratio.toFixed(1) + ':1 in ' + named(el));
                }
                if (bare) say(bare + ' buttons, links, fields or headings without a data-id');
              }
              let left = frames.length;
              function done() {
                const out = known.slice();
                for (const f of frames) check(f, out);
                fit();
                const issues = [...new Set(out)].slice(0, 40);
                webkit.messageHandlers.kelpSync?.postMessage({ kind: 'check', issues: issues });
              }
              if (!left) {
                fit();
                return webkit.messageHandlers.kelpSync?.postMessage({ kind: 'check', issues: known });
              }
              for (const f of frames) {
                const ready = () => { if (--left === 0) setTimeout(done, 50); };
                const d = f.contentDocument;
                if (d && d.URL === 'about:srcdoc' && d.readyState === 'complete') ready();
                else f.addEventListener('load', ready, { once: true });
              }
            })();
            """
    }
}
