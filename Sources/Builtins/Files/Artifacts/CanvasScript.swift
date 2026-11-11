import Foundation

/// Kelp's script beside a canvas (`MarkdownTab.world`; the boards' own don't run): makes each board's frame as tall as
/// what it holds (unless the board's height is fixed), fits the canvas to the pane, and checks what's drawn: text cut
/// off, contrast under 4.5:1, a board wider or taller than its frame, an image that doesn't load, controls without a
/// `data-id`. The result goes to `kelpSync` as `{kind: "check", issues}`, after the files' own (`CanvasPage.lint`), to
/// the column's Check list (`kelp-check` with `window.kelpIssues`), and onto the boards as a `!` on each element at
/// fault.
/// `kelpZoom(z)` sets the canvas's size by hand (nil: fitted to the pane beside the column).
enum CanvasScript {
    static func source(issues: [String]) -> String {
        """
        (function () {
          const known = \(MarkdownTab.js(issues));
          const frames = [...document.querySelectorAll('iframe[data-board]')];
          const canvas = document.getElementById('kelp-canvas');
          // Fits the rows to the pane beside the column (down to a quarter, then it scrolls), or the size set by
          // hand; labels stay readable.
          let chosen = null;
          window.kelpZoom = z => { chosen = z; fit(); };
          function fit() {
            if (!canvas) return;
            canvas.style.transform = '';
            const wide = canvas.scrollWidth + 80;
            const column = document.body.classList.contains('kelp-with-col') ? 260 : 0;
            const room = document.documentElement.clientWidth - column;
            const z = chosen || Math.max(0.25, Math.min(1, room / wide));
            window.kelpZoomNow = z;
            canvas.style.setProperty('--z', z);
            canvas.style.transform = z < 1 ? 'scale(' + z + ')' : '';
            document.body.style.height = z < 1 ? (canvas.scrollHeight * z + 112) + 'px' : '';
            document.body.style.width = z !== 1 ? (canvas.scrollWidth * z + 80) + 'px' : '';
            if (z > 1) document.body.style.height = (canvas.scrollHeight * z + 112) + 'px';
            dispatchEvent(new CustomEvent('kelp-zoom'));
            drawMarkers();
          }
          window.kelpFit = fit;
          // A `!` on each element the check faults, over its board, in the light frame only.
          const faults = [], markers = document.createElement('div');
          markers.className = 'kelp-issues';
          document.body.append(markers);
          function drawMarkers() {
            markers.replaceChildren();
            for (const m of faults) {
              const fr = m.f.getBoundingClientRect(), r = m.el.getBoundingClientRect();
              const k = fr.width / m.f.offsetWidth;
              const b = document.createElement('div');
              b.className = 'kelp-fault'; b.textContent = '!'; b.title = m.text;
              b.style.left = (fr.left + scrollX + (r.left + r.width) * k - 8) + 'px';
              b.style.top = (fr.top + scrollY + r.top * k - 8) + 'px';
              markers.append(b);
            }
          }
          addEventListener('resize', fit);
          new ResizeObserver(() => requestAnimationFrame(fit)).observe(document.documentElement);
        \(checker)
          let left = frames.length;
          function done() {
            const out = known.slice();
            for (const f of frames) check(f, out);
            fit();
            const issues = [...new Set(out)].slice(0, 40);
            window.kelpIssues = issues;
            dispatchEvent(new CustomEvent('kelp-check'));
            webkit.messageHandlers.kelpSync?.postMessage({ kind: 'check', issues: issues });
          }
          if (!left) {
            fit();
            window.kelpIssues = known;
            dispatchEvent(new CustomEvent('kelp-check'));
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

    /// What the check reads on each drawn board (`check(f, out)`), with the colour helpers it needs.
    private static let checker = """
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
              const say = (t, el) => {
                const line = f.dataset.board + (f.dataset.theme === 'dark' ? ' (dark)' : '') + ': ' + t;
                out.push(line);
                const seen = faults.some(m => m.el === el);
                if (el && f.dataset.theme !== 'dark' && !seen) faults.push({ f, el, text: line });
              };
              const root = doc.documentElement, w = +f.dataset.w, h = +(f.dataset.h || 0);
              if (!h) f.style.height = Math.max(60, Math.ceil(doc.body.getBoundingClientRect().height)) + 'px';
              else if (root.scrollHeight > h + 1) say('content is ' + root.scrollHeight + 'px tall, the frame ' + h);
              if (root.scrollWidth > w + 1) say('content is ' + root.scrollWidth + 'px wide, the board ' + w);
              const page = rgb(win.getComputedStyle(doc.body).backgroundColor) || [255, 255, 255, 1];
              let bare = 0;
              for (const el of doc.body.querySelectorAll('*')) {
                const st = win.getComputedStyle(el);
                if (st.display === 'none' || st.visibility === 'hidden') continue;
                // Text kept for screen readers only (a 1-pixel box that clips) is hidden on purpose.
                if (el.clientWidth <= 1 || st.clipPath !== 'none') continue;
                // Its own text, not a child a pixel wider than a box that clips it.
                const text = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
                if (text && ['hidden', 'clip'].includes(st.overflowX) && el.scrollWidth > el.clientWidth + 1)
                  say('text is cut off in ' + named(el), el);
                if (el.tagName === 'IMG' && el.complete && !el.naturalWidth)
                  say('image does not load: ' + el.getAttribute('src'), el);
                const control = 'button, a[href], input, select, textarea, h1, h2, h3';
                if (el.matches(control) && !el.closest('[data-id]')) bare++;
                const fg = text && +st.opacity > 0 && rgb(st.color);
                if (!fg) continue;
                const a = lum(fg), b = lum(ground(win, el, page));
                const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
                const size = parseFloat(st.fontSize), big = size >= 24 || (size >= 18.6 && +st.fontWeight >= 700);
                if (ratio < (big ? 3 : 4.5)) say('contrast ' + ratio.toFixed(1) + ':1 in ' + named(el), el);
              }
              if (bare) say(bare + ' buttons, links, fields or headings without a data-id');
            }
        """
}
