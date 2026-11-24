import Foundation

/// Kelp's script that runs beside a canvas, in `MarkdownTab.world` (the boards' own scripts don't run). It makes each
/// board's frame as tall as its content (unless the board's height is fixed), fits the canvas to the pane, and checks
/// what is drawn: text cut off, contrast under 4.5:1, a board wider or taller than its frame, an image that doesn't
/// load, and controls without a `data-id`. The findings, after those from the files' own checks (`CanvasPage.lint`),
/// go three places: to `kelpSync` as `{kind: "check", issues}`, to the Check list in the column (`kelp-check` with
/// `window.kelpIssues`), and onto the boards as a `!` on each element at fault.
/// With a design system (`system`: its token names by group), it also finds a colour, a font, a text size or a corner
/// radius that isn't a token (naming the nearest), and a picture from the web, which breaks an export and offline
/// viewing.
/// `kelpZoom(z)` sets the canvas's size by hand (nil fits it to the pane beside the column).
enum CanvasScript {
    /// The token groups Check holds the boards to.
    private static let checked = ["color", "font", "size", "radius"]

    static func source(issues: [String], system: [String: [String]] = [:]) -> String {
        """
        (function () {
          const known = \(MarkdownTab.js(issues));
          const SYSTEM = \(MarkdownTab.js(system.filter { Self.checked.contains($0.key) }));
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
            let z = chosen || Math.max(0.25, Math.min(1, room / wide));
            // A motion page's stage fits the pane both ways, in the middle.
            const stage = canvas.classList.contains('kelp-motion');
            const tall = (document.documentElement.clientHeight - 48) / canvas.scrollHeight;
            if (stage && !chosen) z = Math.min(room / wide, tall);
            canvas.style.marginLeft = stage ? Math.max(0, (room - 48 - canvas.scrollWidth * z) / 2) + 'px' : '';
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
              if (!fr.width) continue;   // a board not shown (a dashboard's other view)
              const k = fr.width / m.f.offsetWidth;
              const b = document.createElement('div');
              b.className = 'kelp-fault'; b.innerHTML = \(CanvasChrome.Glyph.warning.js); b.title = m.text;
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
            faults.length = 0;
            for (const f of frames) check(f, out);
            for (const more of window.kelpCheckMore || []) more(out);   // the boards' widths, their flow
            fit();
            const issues = [...new Set(out)].slice(0, 40);
            window.kelpIssues = issues;
            dispatchEvent(new CustomEvent('kelp-check'));
            webkit.messageHandlers.kelpSync?.postMessage({ kind: 'check', issues: issues });
          }
          window.kelpRecheck = () => setTimeout(done, 50);   // the boards drawn differently (another language)
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

    /// The script that checks each drawn board (`check(f, out)`), with the colour helpers it needs.
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
                // A figure says where it came from (`CanvasPage.lint` counts those that don't): a `!` on each.
                if (el.hasAttribute('data-value') && !el.hasAttribute('data-source') && f.dataset.theme !== 'dark'
                  && !faults.some(m => m.el === el))
                  faults.push({ f, el, text: f.dataset.board + ': a figure without data-source (where it came from)' });
                const fg = text && +st.opacity > 0 && rgb(st.color);
                if (!fg) continue;
                const a = lum(fg), b = lum(ground(win, el, page));
                const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
                const size = parseFloat(st.fontSize), big = size >= 24 || (size >= 18.6 && +st.fontWeight >= 700);
                if (ratio < (big ? 3 : 4.5)) say('contrast ' + ratio.toFixed(1) + ':1 in ' + named(el), el);
              }
              if (bare) say(bare + ' buttons, links, fields or headings without a data-id');
              access(doc, win, say);
              systemFaults(f, doc, win, say);
            }
            // What VoiceOver would miss (Webflow's Audit): a picture without words, a button or a link without a name,
            // a heading level skipped, and an order CSS shows differently from how it is read.
            function access(doc, win, say) {
              const shown = el => win.getComputedStyle(el).display !== 'none' && !el.closest('[aria-hidden="true"]');
              for (const img of doc.body.querySelectorAll('img:not([alt])')) {
                if (shown(img)) say('picture without a description (alt) in ' + named(img), img);
              }
              for (const el of doc.body.querySelectorAll('button, a[href], [role="button"]')) {
                const words = (el.textContent || '').trim() || el.getAttribute('aria-label') || el.getAttribute('title')
                  || [...el.querySelectorAll('img[alt]')].map(i => i.alt).join('');
                if (!words && !el.hasAttribute('aria-labelledby') && shown(el))
                  say((el.tagName === 'A' ? 'link' : 'button') + ' without a name in ' + named(el), el);
              }
              let last = 0;
              for (const h of doc.body.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
                const level = +h.tagName[1];
                if (last && level > last + 1 && shown(h))
                  say('h' + level + ' after h' + last + ' in ' + named(h) + ': skips a level', h);
                last = level;
              }
              for (const el of doc.body.querySelectorAll('*')) {
                const st = win.getComputedStyle(el);
                const turned = /reverse/.test(st.flexDirection) || [...el.children].some(c =>
                  win.getComputedStyle(c).order !== '0');
                if (turned && el.children.length > 1 && /flex|grid/.test(st.display) && shown(el))
                  say('reading order differs from what is seen in ' + named(el) + ' (order or a reversed row)', el);
              }
            }
            // The design system's tokens as this board resolves them: colours by name, fonts by first family.
            const hex = c => '#' + c.slice(0, 3).map(v => Math.round(v).toString(16).padStart(2, '0')).join('');
            function tokens(win, doc) {
              const st = win.getComputedStyle(doc.documentElement), probe = doc.createElement('i');
              doc.body.append(probe);
              const colours = (SYSTEM.color || []).map(name => {
                probe.style.color = st.getPropertyValue('--' + name).trim();
                return { name, c: rgb(win.getComputedStyle(probe).color) };
              }).filter(t => t.c && probe.style.color);
              probe.remove();
              const first = v => v.split(',')[0].trim().replace(/^['"]|['"]$/g, '').toLowerCase();
              const fonts = (SYSTEM.font || []).map(n => st.getPropertyValue('--font-' + n).trim()).filter(Boolean)
                .map(first);
              // Sizes and radii as this board resolves them, in pixels.
              const px = (group, prop) => (SYSTEM[group] || []).map(name => {
                probe.style[prop] = 'var(--' + group + '-' + name + ')';
                doc.body.append(probe);
                const v = parseFloat(win.getComputedStyle(probe)[prop]);
                probe.remove(); probe.removeAttribute('style');
                return { name, v };
              }).filter(t => t.v > 0);
              const sizes = px('size', 'fontSize'), radii = px('radius', 'borderTopLeftRadius');
              return { colours, fonts, first, sizes, radii };
            }
            function systemFaults(f, doc, win, say) {
              for (const img of doc.body.querySelectorAll('img[src^="http"], video[src^="http"]'))
                say('picture from the web in ' + named(img) + ': it breaks an export and offline viewing; '
                  + 'copy it beside the page', img);
              if (!SYSTEM.color && !SYSTEM.font && !SYSTEM.size && !SYSTEM.radius) return;
              const t = tokens(win, doc), seen = new Set();
              const near = c => t.colours.map(k => ({ k, d: Math.hypot(k.c[0] - c[0], k.c[1] - c[1], k.c[2] - c[2]) }))
                .sort((a, b) => a.d - b.d)[0];
              for (const el of doc.body.querySelectorAll('*')) {
                const st = win.getComputedStyle(el);
                if (st.display === 'none') continue;
                const text = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
                for (const c of [text && rgb(st.color), rgb(st.backgroundColor)]) {
                  if (!c || c[3] < 0.5 || !t.colours.length) continue;
                  const n = near(c);
                  if (!n || n.d < 3 || seen.has(hex(c))) continue;
                  seen.add(hex(c));
                  say('colour ' + hex(c) + ' in ' + named(el) + ' is not a token (nearest: ' + n.k.name + ' '
                    + hex(n.k.c) + ')', el);
                }
                // A size or a radius a pixel off every token: the nearest named.
                const off = (list, v, what) => {
                  if (!list.length || !(v > 0) || list.some(k => Math.abs(k.v - v) < 0.5) || seen.has(what + v)) return;
                  seen.add(what + v);
                  const n = list.reduce((a, b) => Math.abs(b.v - v) < Math.abs(a.v - v) ? b : a);
                  say(what + ' ' + Math.round(v) + 'px in ' + named(el) + ' is not a token (nearest: ' + n.name + ' '
                    + Math.round(n.v) + 'px)', el);
                };
                if (text) off(t.sizes, parseFloat(st.fontSize), 'size');
                off(t.radii, parseFloat(st.borderTopLeftRadius), 'radius');
                const family = text && t.fonts.length && t.first(st.fontFamily);
                if (family && !t.fonts.includes(family) && !seen.has(family)) {
                  seen.add(family);
                  say('font ' + family + ' in ' + named(el) + ' is not a token (' + t.fonts.join(', ') + ')', el);
                }
              }
            }
        """
}
