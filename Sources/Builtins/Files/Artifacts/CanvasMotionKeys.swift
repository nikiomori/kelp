import Foundation

/// The column's Motion section on a motion page, for the chosen element's first animation: its keyframes (◀ ◆ ▶ step
/// the time from one to the next and put or take away one at the time) and the easing of the stretch the time is in.
/// Its easing, or a keyframe's Edit Curve… (`kelpCurve`), opens the curve: Curve (a cubic-bézier, its two handles
/// dragged or typed), Spring (a bounce) or Wiggle (a count and a size), and tiles of ready ones. Spring and wiggle are
/// written as CSS `linear()`, sampled, so the page needs no script. A choice goes to the tab as `ease`.
enum CanvasMotionKeys {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas, props = window.kelpProps; if (!K || !props || !window.kelpMotion) return;
          let curve = null;   // { id, at } while the curve is open
          const presets = [['Linear', 'linear'], ['Out', 'ease-out'], ['In Out', 'ease-in-out'],
            ['Back', 'cubic-bezier(.34, 1.56, .64, 1)'], ['Expo', 'cubic-bezier(.16, 1, .3, 1)'],
            ['Gentle', spring(0.2)], ['Bouncy', spring(0.6)], ['Hold', 'steps(1, end)']];
          // The same easing however it's written: WebKit gives `cubic-bezier(0.34, 1.56, 0.64, 1)` for `.34, …`.
          const same = (a, b) => String(a).replace(/\\s+/g, '').replace(/(^|[(,])0[.]/g, '$1.')
            === String(b).replace(/\\s+/g, '').replace(/(^|[(,])0[.]/g, '$1.');
          // A damped spring sampled as CSS linear(): `bounce` 0 settles at once, 1 rings long.
          function spring(bounce) {
            const damp = 9 - bounce * 6, freq = 10 + bounce * 8, pts = [];
            for (let i = 0; i <= 20; i++) {
              const t = i / 20, v = 1 - Math.exp(-damp * t) * Math.cos(freq * t);
              pts.push((Math.round((i === 20 ? 1 : v) * 1000) / 1000) + ' ' + i * 5 + '%');
            }
            return 'linear(' + pts.join(', ') + ')';
          }
          // A wiggle around the way: `count` swings of `size`, ending still.
          function wiggle(count, size) {
            const pts = [];
            for (let i = 0; i <= 24; i++) {
              const t = i / 24, v = t + Math.sin(t * Math.PI * 2 * count) * size * (1 - t);
              pts.push((Math.round(v * 1000) / 1000) + ' ' + Math.round(t * 1000) / 10 + '%');
            }
            return 'linear(' + pts.join(', ') + ')';
          }
          const keysOf = e => {
            const a = e.getAnimations()[0]; if (!a || !a.animationName) return null;
            const t = a.effect.getComputedTiming();
            return { delay: (t.delay || 0) / 1000, duration: (t.duration || 0) / 1000,
              frames: a.effect.getKeyframes().map(k => ({ at: k.computedOffset * 100, easing: k.easing })) };
          };
          const place = (keys, t) => keys.duration ? (t - keys.delay) / keys.duration * 100 : 0;
          const ease = (id, at, value) => K.post({ kind: 'ease', id, at, value });
          function bezier(v) {
            const m = String(v).match(/cubic-bezier[(]([^)]*)[)]/);
            const named = { linear: [0, 0, 1, 1], ease: [.25, .1, .25, 1], 'ease-in': [.42, 0, 1, 1],
              'ease-out': [0, 0, .58, 1], 'ease-in-out': [.42, 0, .58, 1] };
            return m ? m[1].split(',').map(Number) : named[v] || [.42, 0, .58, 1];
          }
          // The curve: a square plot with room above and below, the two handles on lines from the corners.
          function plot(id, at, now) {
            const [x1, y1, x2, y2] = bezier(now), W = 200, H = 150, top = 20, h = 110;
            const px = x => 20 + x * 160, py = y => top + h - y * h;
            const NS = 'http://www.w3.org/2000/svg', svg = document.createElementNS(NS, 'svg');
            svg.setAttribute('width', W); svg.setAttribute('height', H); svg.classList.add('kelp-curve');
            const path = (d, cls) => { const p = document.createElementNS(NS, 'path'); p.setAttribute('d', d);
              p.setAttribute('class', cls); svg.append(p); return p; };
            path('M20 ' + (top + h) + ' L180 ' + top, 'kelp-cv-diag');
            const line = path('', 'kelp-cv-line'), arms = path('', 'kelp-cv-arm');
            const knobs = [0, 1].map(() => { const c = document.createElementNS(NS, 'circle'); c.setAttribute('r', 5);
              c.setAttribute('class', 'kelp-cv-knob'); svg.append(c); return c; });
            const pts = [x1, y1, x2, y2];
            const draw = () => {
              const a = px(pts[0]) + ' ' + py(pts[1]), b = px(pts[2]) + ' ' + py(pts[3]), o = 'M20 ' + (top + h);
              line.setAttribute('d', o + ' C ' + a + ', ' + b + ', 180 ' + top);
              arms.setAttribute('d', o + ' L' + a + ' M180 ' + top + ' L' + b);
              knobs.forEach((k, i) => {
                k.setAttribute('cx', px(pts[i * 2])); k.setAttribute('cy', py(pts[i * 2 + 1]));
              });
            };
            draw();
            const value = () => 'cubic-bezier(' + pts.map(v => Math.round(v * 100) / 100).join(', ') + ')';
            knobs.forEach((k, i) => k.addEventListener('mousedown', ev => {
              ev.preventDefault(); ev.stopPropagation();
              const r = svg.getBoundingClientRect();
              const move = m => {
                pts[i * 2] = Math.min(Math.max((m.clientX - r.left - 20) / 160, 0), 1);
                pts[i * 2 + 1] = Math.round(((top + h - (m.clientY - r.top)) / h) * 100) / 100;
                draw();
              };
              const up = () => {
                removeEventListener('mousemove', move); removeEventListener('mouseup', up); ease(id, at, value());
              };
              addEventListener('mousemove', move); addEventListener('mouseup', up);
            }));
            const fields = K.el('div', 'kelp-cv-fields');
            pts.forEach((v, i) => {
              const f = K.el('input', 'kelp-cv-num'); f.value = Math.round(v * 100) / 100;
              f.onchange = () => { pts[i] = +f.value || 0; draw(); ease(id, at, value()); };
              f.onkeydown = ev => ev.stopPropagation();
              fields.append(f);
            });
            return [svg, fields];
          }
          function curveSection(e, id) {
            const keys = keysOf(e); if (!keys) return null;
            const i = Math.max(0, keys.frames.findIndex(f => Math.abs(f.at - curve.at) < 0.6));
            const now = keys.frames[i] ? keys.frames[i].easing : 'linear';
            const kind = /^linear[(]/.test(now) ? (now.split(',').length > 22 ? 'wiggle' : 'spring') : 'curve';
            const s = K.el('div', 'kelp-isec');
            const head = K.el('div', 'kelp-ititle', L.easing + ' · ' + Math.round(curve.at) + '%');
            const seg = K.el('span', 'kelp-seg kelp-fill kelp-cv-seg');
            for (const [k, name] of [['curve', L.curve], ['spring', L.spring], ['wiggle', L.wiggle]]) {
              const b = K.el('button', k === kind ? 'on' : '', name);
              const first = { curve: 'ease-in-out', spring: spring(0.5), wiggle: wiggle(3, 0.12) }[k];
              b.onclick = () => ease(id, curve.at, first);
              seg.append(b);
            }
            s.append(head, seg);
            if (kind === 'curve') s.append(...plot(id, curve.at, now));
            else {
              const f = K.el('input', 'kelp-cv-num');
              f.value = kind === 'spring' ? 0.5 : 3;
              f.title = kind === 'spring' ? L.bounce : L.count;
              f.onchange = () => ease(id, curve.at, kind === 'spring' ? spring(Math.min(Math.max(+f.value, 0), 1))
                : wiggle(Math.max(1, Math.round(+f.value)), 0.12));
              f.onkeydown = ev => ev.stopPropagation();
              const r = K.el('div', 'kelp-irow');
              r.append(K.el('span', 'kelp-ilabel', kind === 'spring' ? L.bounce : L.count), f, K.el('span'));
              s.append(r);
            }
            const tiles = K.el('div', 'kelp-cv-tiles');
            for (const [name, value] of presets) {
              const t = K.el('button', 'kelp-cv-tile' + (same(value, now) ? ' on' : ''), name);
              t.onclick = () => ease(id, curve.at, value);
              tiles.append(t);
            }
            s.append(K.el('div', 'kelp-ititle kelp-cv-sub', L.presets), tiles);
            return s;
          }
          function motionSection(e, id) {
            const keys = keysOf(e); if (!keys) return [];
            const t = window.kelpMotion.time(), p = place(keys, t);
            const times = keys.frames.map(f => keys.delay + keys.duration * f.at / 100);
            const nav = K.el('span', 'kelp-step');
            const go = d => {
              const next = d < 0 ? times.filter(x => x < t - 0.01).pop() : times.find(x => x > t + 0.01);
              if (next != null) window.kelpMotion.seek(next);
            };
            const on = keys.frames.some(f => Math.abs(f.at - p) < 0.6);
            const steps = [['chevron-left', () => go(-1), ''],
              ['diamond-fill', () => K.post({ kind: 'keyframe' }), on ? 'on' : ''], ['chevron-right', () => go(1), '']];
            for (const [glyph, run, cls] of steps) {
              const b = K.el('button', 'kelp-ib ' + cls); b.append(K.el('span', 'kelp-sym-' + glyph)); b.onclick = run;
              nav.append(b);
            }
            const seg = keys.frames.filter(f => f.at <= p + 0.01).pop() || keys.frames[0];
            const easing = K.el('button', 'kelp-ipop');
            easing.append(K.el('span', 'kelp-itok', (presets.find(([, v]) => same(v, seg.easing)) || [seg.easing])[0]));
            easing.onclick = () => window.kelpCurve(id, seg.at);
            const row = (label, control) => { const r = K.el('div', 'kelp-irow');
              r.append(K.el('span', 'kelp-ilabel', label), control, K.el('span')); return r; };
            const s = K.el('div', 'kelp-isec');
            s.append(K.el('div', 'kelp-ititle', L.motion), row(L.keyframes, nav), row(L.easing, easing));
            const out = [s];
            if (curve && curve.id === id) { const c = curveSection(e, id); if (c) out.push(c); }
            return out;
          }
          // Entrance and exit by hand (`MotionPresets`): what, how long, how eased; the tab writes them.
          function presetSection(e, id) {
            if (!id) return [];
            const scene = e.closest('[data-start]') || e, start = +scene.dataset.start || 0;
            const end = start + (+scene.dataset.duration || window.kelpMotion.duration() - start);
            const s = K.el('div', 'kelp-isec');
            s.append(K.el('div', 'kelp-ititle', L.entrance));
            for (const which of ['in', 'out']) {
              const now = (e.dataset['kelp' + (which === 'in' ? 'In' : 'Out')] || '').split(' ');
              const ask = field => K.post({ kind: 'animMenu', id, which, field, start, end, now: now.join(' ') });
              const how = K.el('button', 'kelp-ipop');
              how.append(K.el('span', 'kelp-itok', now[0] ? (L[now[0]] || now[0]) : '—'));
              how.onclick = () => ask('how');
              const r = K.el('div', 'kelp-irow');
              r.append(K.el('span', 'kelp-ilabel', which === 'in' ? L.comes : L.goes), how, K.el('span'));
              s.append(r);
              if (!now[0]) continue;
              const len = K.el('input', 'kelp-cv-num'); len.value = now[1] + ' s';
              len.onchange = () => K.post({ kind: 'animLength', id, which, start, end, now: now.join(' '),
                length: parseFloat(len.value) || 0.6 });
              len.onkeydown = ev => ev.stopPropagation();
              const ease = K.el('button', 'kelp-ipop'); ease.append(K.el('span', 'kelp-itok', now[2] || 'ease-out'));
              ease.onclick = () => ask('ease');
              const r2 = K.el('div', 'kelp-irow');
              r2.append(K.el('span', 'kelp-ilabel', L.length + ' · ' + L.easing), len, ease);
              s.append(r2);
            }
            return [s];
          }
          // The subtitles' look, for a cue or their block: a box, plain, an outline or a highlight; where; how big.
          function captionSection(e) {
            const block = e.closest('[data-kelp-captions]'); if (!block) return [];
            const [look, place, size] = (block.dataset.kelpCaptions || 'box bottom 48').split(' ');
            const pop = (field, value) => {
              const b = K.el('button', 'kelp-ipop'); b.append(K.el('span', 'kelp-itok', L[value] || value));
              b.onclick = () => K.post({ kind: 'captionMenu', field }); return b;
            };
            const big = K.el('input', 'kelp-cv-num'); big.value = size;
            big.onchange = () => K.post({ kind: 'captionSize', size: parseInt(big.value) || 48 });
            big.onkeydown = ev => ev.stopPropagation();
            const s = K.el('div', 'kelp-isec');
            s.append(K.el('div', 'kelp-ititle', L.subtitles));
            const rows = [[L.look, pop('look', look)], [L.place, pop('place', place)], [L.size, big]];
            for (const [label, control] of rows) {
              const r = K.el('div', 'kelp-irow');
              r.append(K.el('span', 'kelp-ilabel', label), control, K.el('span'));
              s.append(r);
            }
            return [s];
          }
          // A sound's volume, where in its file it starts, and how it fades in and out (`data-volume`, `data-from`,
          // `data-fade-in`, `data-fade-out`).
          function soundSection(e, id) {
            if (e.tagName !== 'AUDIO' || !id) return [];
            const field = (name, value, unit) => {
              const f = K.el('input', 'kelp-cv-num'); f.value = value + (unit ? ' ' + unit : '');
              f.onchange = () => K.post({ kind: 'soundProp', id, name, value: String(parseFloat(f.value) || 0) });
              f.onkeydown = ev => ev.stopPropagation();
              return f;
            };
            // The column's slider, as Opacity's: the bar filled to the value, the value beside it.
            const volume = K.el('span', 'kelp-islide'), range = K.el('input'), pct = K.el('span', 'kelp-ival');
            range.type = 'range'; range.min = 0; range.max = 100; range.value = e.dataset.volume || 100;
            const show = () => {
              pct.textContent = range.value + ' %'; range.style.setProperty('--v', range.value + '%');
            };
            show();
            range.oninput = show;
            range.onchange = () => K.post({ kind: 'soundProp', id, name: 'volume', value: range.value });
            volume.append(range, pct);
            const pair = K.el('span', 'kelp-ipair');
            pair.append(field('fade-in', e.dataset.fadeIn || 0, 's'), field('fade-out', e.dataset.fadeOut || 0, 's'));
            // Quieter under the other sounds (a voice), by so many decibels; brought to a loudness at export.
            const choice = (name, now, options) => {
              const seg = K.el('span', 'kelp-seg kelp-fill');
              for (const [v, t] of options) {
                const b = K.el('button', String(now || 0) === v ? 'on' : '', t);
                b.onclick = () => K.post({ kind: 'soundProp', id, name, value: v });
                seg.append(b);
              }
              return seg;
            };
            const duck = choice('duck', e.dataset.duck, [['0', L.off], ['6', '−6'], ['12', '−12'], ['18', '−18']]);
            const level = choice('loudness', e.dataset.loudness,
              [['0', L.asIs], ['-23', '−23'], ['-16', '−16'], ['-14', '−14']]);
            duck.title = L.duckTip; level.title = L.loudnessTip;
            const s = K.el('div', 'kelp-isec');
            s.append(K.el('div', 'kelp-ititle', L.sound));
            const rows = [[L.volume, volume], [L.from, field('from', e.dataset.from || 0, 's')], [L.fades, pair],
              [L.duck, duck], [L.loudness, level]];
            for (const [label, control] of rows) {
              const r = K.el('div', 'kelp-irow');
              r.append(K.el('span', 'kelp-ilabel', label), control, K.el('span'));
              s.append(r);
            }
            return [s];
          }
          // A video's speed (0.25–4×, `data-rate`) and whether it starts again when it ends (`data-loop`).
          function videoSection(e, id) {
            if (e.tagName !== 'VIDEO' || !id) return [];
            const speed = K.el('input', 'kelp-cv-num');
            speed.value = (e.dataset.rate || 1) + '×';
            speed.onkeydown = ev => ev.stopPropagation();
            speed.onchange = () => K.post({ kind: 'soundProp', id, name: 'rate',
              value: String(Math.max(0.25, Math.min(4, parseFloat(speed.value) || 1))) });
            const loop = K.el('span', 'kelp-seg kelp-fill');
            for (const [v, t] of [['', L.no], ['true', L.yes]]) {
              const b = K.el('button', (e.dataset.loop || '') === v ? 'on' : '', t);
              b.onclick = () => K.post({ kind: 'soundProp', id, name: 'loop', value: v || '0' });
              loop.append(b);
            }
            const s = K.el('div', 'kelp-isec');
            s.append(K.el('div', 'kelp-ititle', L.video));
            for (const [label, control] of [[L.speed, speed], [L.loop, loop]]) {
              const r = K.el('div', 'kelp-irow');
              r.append(K.el('span', 'kelp-ilabel', label), control, K.el('span'));
              s.append(r);
            }
            return [s];
          }
          props.more = (props.more || []).concat([motionSection, presetSection, captionSection, soundSection,
            videoSection]);
          window.kelpCurve = (id, at) => { curve = { id, at }; props.redraw?.(); };
          addEventListener('kelp-chosen', ev => {
            if (!ev.detail || (curve && ev.detail.e.getAttribute('data-id') !== curve.id)) curve = null;
          });
        """

    static let style = """
        .kelp-curve { display: block; margin: 8px 0; }
        .kelp-cv-diag { stroke: var(--k-sep); stroke-dasharray: 4 4; fill: none; }
        .kelp-cv-line { stroke: var(--k-label); stroke-width: 2; fill: none; }
        .kelp-cv-arm { stroke: var(--k-accent); stroke-width: 1.2; fill: none; }
        .kelp-cv-knob { fill: var(--k-accent); cursor: grab; }
        .kelp-cv-fields { display: grid; grid-template-columns: repeat(4, 1fr); gap: 4px; }
        .kelp-cv-num { width: 100%; min-width: 0; height: 20px; border: 0;
          border-radius: var(--k-radius-sm); padding: 0 6px;
          background: var(--k-card); box-shadow: inset 0 0 0 1px var(--k-sep); color: var(--k-label);
          font: var(--k-text-row) -apple-system, sans-serif; font-variant-numeric: tabular-nums; }
        .kelp-cv-seg { margin: 4px 0; }
        .kelp-cv-sub { margin-top: 8px; }
        .kelp-cv-tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 4px; }
        .kelp-cv-tile { height: 30px; border: 0;
          border-radius: var(--k-radius-sm); background: var(--k-hover); color: var(--k-sec);
          font: var(--k-text-micro) -apple-system, sans-serif; }
        .kelp-cv-tile.on { background: var(--k-sel); color: var(--k-label); }
        """
}
