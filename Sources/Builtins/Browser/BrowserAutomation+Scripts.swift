// The page scripts behind kelp browser: snapshot, find, click, type, upload, drag, wait, hover, press, scroll.
import AppKit
import Core
import DesignKit
import WebKit
import WorkbenchKit

extension BrowserTab {
    /// Counts what changes in the page (and the site's own frames in it), so an action can say whether it did anything:
    /// `__kelpN` real changes, `__kelpLast` when the last one was, `__kelpDoc` which document this is, `__kelpAdded`
    /// the nodes added (or texts rewritten) since the last whole snapshot. Kelp's own pointer and glow aren't the page
    /// reacting; an attribute written with the value it had is nothing, and a style only counts as the first on its
    /// element in 200 ms (a menu shown by `display` is a change, an animation loop goes quiet).
    static let observeJS = #"""
        const W = window;
        if (!W.__kelpObs) {
          W.__kelpObs = true; W.__kelpN = 0; W.__kelpLast = performance.now(); W.__kelpDoc = Math.random();
          W.__kelpAdded = new WeakSet();
        }
        const ours = n => {
          const e = n && (n.nodeType === 1 ? n : n.parentElement);
          return !!(e && e.closest('[data-kelp-flash]'));
        };
        const watch = win => {
          let doc = null; try { doc = win.document; } catch (_) {}
          if (!doc || doc.__kelpWatched) return;
          doc.__kelpWatched = true;
          const styled = new WeakMap();
          new MutationObserver(records => {
            const now = performance.now(); let real = false;
            for (const r of records) {
              if (ours(r.target) || [...r.addedNodes, ...r.removedNodes].some(ours)) continue;
              if (r.type === 'attributes') {
                if (r.oldValue === r.target.getAttribute(r.attributeName)) continue;
                if (r.attributeName === 'style') {
                  const at = styled.get(r.target) ?? -1e9; styled.set(r.target, now);
                  if (now - at <= 200) continue;
                }
              }
              real = true;
              for (const n of r.addedNodes) W.__kelpAdded.add(n);
              if (r.type === 'characterData') W.__kelpAdded.add(r.target);
            }
            if (real) { W.__kelpLast = now; W.__kelpN++; }
          }).observe(doc, {subtree: true, childList: true, attributes: true, attributeOldValue: true,
            characterData: true});
        };
        const frames = win => {
          watch(win);
          for (let i = 0; i < win.frames.length; i++) {
            try { if (win.frames[i].document) frames(win.frames[i]); } catch (_) {}
          }
        };
        frames(W);
        """#

    /// Where the page is and how long it has been still (ms), for an action's `change`.
    static var probeJS: String { observeJS + probeBody }
    private static let probeBody = #"""
        return {doc: W.__kelpDoc, url: location.href, n: W.__kelpN, idle: performance.now() - W.__kelpLast,
          ready: document.readyState};
        """#

    /// `textShown(el)`: the text in `el` is there for a person: laid out, not hidden and not transparent. A toast drawn
    /// ahead at opacity 0 says "Saved" only to a script. `display: contents` has no box: its parent's says.
    static let shownTextJS = #"""
        const OPAQUE = {opacityProperty: true, checkOpacity: true, visibilityProperty: true}, opaque = new Map();
        const textShown = e => {
          if (!e || !e.checkVisibility) return true;
          if (!opaque.has(e)) {
            const box = e.checkVisibility(OPAQUE);
            opaque.set(e, box || getComputedStyle(e).display === 'contents' && textShown(e.parentElement));
          }
          return opaque.get(e);
        };
        """#

    /// The page as an accessibility tree, a line an element: role, name, state, and a ref (`e12`) for what can be
    /// clicked or typed in. An element keeps its ref while it's on the page; what came since the last whole snapshot
    /// says `[new]`. Elements without a role don't show, their children do, one level up; links, buttons and fields
    /// show their text, not what's inside them. A frame of the page's own site is read too; another site's can't be.
    /// Over `max` lines the middle goes: a dialog's buttons are usually the page's last lines.
    static var snapshotJS: String { observeJS + shownTextJS + snapshotBody }
    private static let snapshotBody = #"""
        if (!W.__kelpRefs) { W.__kelpRefs = new Map(); W.__kelpIds = new WeakMap(); W.__kelpNext = 0; }
        const refs = W.__kelpRefs, ids = W.__kelpIds;
        for (const [k, e] of refs) if (!e.isConnected) refs.delete(k);
        const root = ref ? refs.get(ref) : document.body;
        if (ref && !root) throw new Error('No ' + ref + ' on the page now: take a new snapshot');
        const added = W.__kelpLooked ? W.__kelpAdded : new WeakSet();
        if (!ref) { W.__kelpLooked = true; W.__kelpAdded = new WeakSet(); }
        const refOf = el => {
          let r = ids.get(el);
          if (!r) ids.set(el, r = 'e' + ++W.__kelpNext);
          refs.set(r, el);
          return r;
        };
        const out = [], HARD = 20000;
        const ACT = new Set(['link','button','textbox','searchbox','checkbox','radio','combobox','listbox','slider','switch','tab',
          'menuitem','menuitemcheckbox','menuitemradio','option','spinbutton','treeitem','clickable','draggable']);
        const LEAF = new Set(['link','button','textbox','searchbox','checkbox','radio','combobox','slider','switch','tab','menuitem',
          'option','spinbutton','img','heading','clickable','draggable']);
        const FIELD = new Set(['textbox','searchbox','combobox','slider','spinbutton']);
        // One with buttons, links or fields inside (a card that's a link, a menu opened by hover) lists them, each with a ref.
        const INNER = 'a[href],button,input,select,textarea,[role=button],[role=link],[role=menuitem],[role=checkbox],[role=tab]';
        const leaf = (el, role) => LEAF.has(role) && (FIELD.has(role) || !el.querySelector(INNER));
        const clean = s => (typeof s === 'string' ? s : '').replace(/\s+/g, ' ').trim();
        const cut = s => (s = s || '').length > 100 ? s.slice(0, 100) + '…' : s;
        const SKIP = new Set(['script','style','noscript','template','head','svg']);
        const INPUT = {checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton', button: 'button', submit: 'button',
          reset: 'button', image: 'button', file: 'button', search: 'searchbox'};
        const TAG = {button: 'button', summary: 'button', textarea: 'textbox', h1: 'heading', h2: 'heading', h3: 'heading', h4: 'heading',
          h5: 'heading', h6: 'heading', nav: 'navigation', main: 'main', dialog: 'dialog', ul: 'list', ol: 'list', li: 'listitem',
          table: 'table', tr: 'row', td: 'cell', th: 'columnheader', form: 'form'};
        const roleOf = el => {
          const r = el.getAttribute('role'); if (r) return r.split(' ')[0];
          const t = el.localName;
          if (t === 'a') return el.hasAttribute('href') ? 'link' : null;
          if (t === 'input') return el.type === 'hidden' ? null : INPUT[el.type] || 'textbox';
          if (t === 'select') return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
          if (t === 'img') return el.getAttribute('alt') === '' ? null : 'img';
          if (TAG[t]) return TAG[t];
          if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
          if (el.getAttribute('draggable') === 'true') return 'draggable';
          const cs = getComputedStyle(el), grab = c => c === 'grab' || c === 'move';
          const up = el.parentElement;
          if (grab(cs.cursor) && !(up && grab(getComputedStyle(up).cursor))) return 'draggable';
          if (cs.cursor === 'pointer' && !(el.parentElement && getComputedStyle(el.parentElement).cursor === 'pointer')) return 'clickable';
          return null;
        };
        const byId = (el, id) => {
          const root = el.getRootNode();
          return (root.getElementById ? root : el.ownerDocument).getElementById(id);
        };
        const nameOf = (el, role) => {
          const l = el.getAttribute('aria-label'); if (l) return clean(l);
          const by = el.getAttribute('aria-labelledby');
          if (by) {
            const s = clean(by.split(/\s+/).map(id => (byId(el, id) || {}).innerText || '').join(' '));
            if (s) return s;
          }
          if (el.labels && el.labels.length) return clean([...el.labels].map(x => x.innerText).join(' '));
          if (el.localName === 'img') return clean(el.alt || el.getAttribute('title'));
          if (el.localName === 'input' && ['button', 'submit', 'reset'].includes(el.type)) return clean(el.value);
          if (FIELD.has(role)) return clean(el.placeholder || el.getAttribute('title'));
          if (leaf(el, role)) return clean(el.innerText || el.getAttribute('title'));
          return clean(el.getAttribute('title'));
        };
        const shown = el => {
          if (el.getAttribute('aria-hidden') === 'true') return false;
          if (el.checkVisibility ? el.checkVisibility({visibilityProperty: true}) : el.getClientRects().length) return true;
          return getComputedStyle(el).display === 'contents';
        };
        const kids = el => el.shadowRoot ? el.shadowRoot.childNodes
          : el.localName === 'slot' && el.assignedNodes().length ? el.assignedNodes() : el.childNodes;
        const frame = (el, pad, depth, fresh) => {
          let doc = null; try { doc = el.contentDocument; } catch (_) {}
          const name = clean(el.title || el.name), src = el.getAttribute('src');
          let line = pad + '- iframe' + (name ? ' ' + JSON.stringify(cut(name)) : '') + (src ? ' -> ' + cut(src) : '');
          if (!doc || !doc.body) line += " (another site's page: Kelp can't read it; a screenshot shows it)";
          out.push(line + (fresh ? ' [new]' : ''));
          if (doc && doc.body) walk([doc.body], depth + 1, fresh);
        };
        const walk = (nodes, depth, fresh) => {
          for (const node of nodes) {
            if (out.length >= HARD) return;
            const pad = '  '.repeat(depth), now = fresh || added.has(node), mark = now ? ' [new]' : '';
            if (node.nodeType === 3) {
              const t = clean(node.textContent);
              if (t && textShown(node.parentElement)) out.push(pad + '- text: ' + JSON.stringify(cut(t)) + mark);
              continue;
            }
            if (node.nodeType !== 1 || SKIP.has(node.localName) || !shown(node)) continue;
            const el = node;
            if (el.localName === 'iframe' || el.localName === 'frame') { frame(el, pad, depth, now); continue; }
            const role = roleOf(el);
            if (!role) { walk(kids(el), depth, now); continue; }
            let line = pad + '- ' + role;
            const name = nameOf(el, role); if (name) line += ' ' + JSON.stringify(cut(name));
            if (role === 'heading') line += ' [level=' + (el.getAttribute('aria-level') || el.localName.slice(1)) + ']';
            if (el.checked || el.getAttribute('aria-checked') === 'true') line += ' [checked]';
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' [disabled]';
            const ex = el.getAttribute('aria-expanded'); if (ex) line += ' [expanded=' + ex + ']';
            if (ACT.has(role)) line += ' [ref=' + refOf(el) + ']';
            if (role === 'link' && el.getAttribute('href')) line += ' -> ' + cut(el.getAttribute('href'));
            if (FIELD.has(role)) {
              // A password's value never leaves the page: that one is typed says enough.
              const v = el.type === 'password' ? (el.value ? '••••••' : '')
                : clean(el.isContentEditable ? el.innerText : el.localName === 'select' ? (el.selectedOptions[0] || {}).text : el.value);
              if (v) line += ': ' + JSON.stringify(cut(v));
            }
            out.push(line + mark);
            if (!leaf(el, role)) walk(kids(el), depth + 1, now);
          }
        };
        walk(root ? [root] : [], 0, false);
        let body = out;
        if (out.length > max) {
          const head = Math.floor(max * 0.8), tail = max - head;
          const gap = '… ' + (out.length - head - tail) + ' lines cut here: snapshot <ref> or --find <text> shows them';
          body = [...out.slice(0, head), gap, ...out.slice(out.length - tail)];
        }
        if (out.length >= HARD) body.push('… and more past ' + HARD + ' lines');
        if (!out.length) {
          body = ['(nothing to read: the page is blank or still loading, or it draws on a canvas or shows another '
            + "site's frame: take a screenshot)"];
        }
        return '- page ' + JSON.stringify(document.title) + ' ' + location.href + '\n' + body.join('\n');
        """#

    /// `el`: the element of `ref` from the last snapshot, scrolled into view. `box(e)`: where an element is in the top
    /// page (a frame's own place added: its elements' boxes are the frame's).
    static let findJS = #"""
        const el = window.__kelpRefs && window.__kelpRefs.get(ref);
        if (!el || !el.isConnected) throw new Error('No ' + ref + ' on the page now: take a new snapshot');
        el.scrollIntoView({block: 'center', inline: 'center'});
        const box = e => {
          const r = e.getBoundingClientRect(); let x = r.left, y = r.top;
          for (let w = e.ownerDocument.defaultView; w && w.frameElement; w = w.parent) {
            const f = w.frameElement, fr = f.getBoundingClientRect();
            x += fr.left + f.clientLeft; y += fr.top + f.clientTop;
          }
          return {left: x, top: y, width: r.width, height: r.height};
        };
        """#

    /// `el` takes a pointer as it would a person's: enabled, shown, and not under something else at its middle (a
    /// cookie banner, a dialog's backdrop): a script's events would reach it anyway, a person's click wouldn't. A box
    /// under its own label and (`editable`) a field under the field a combobox lays over it count as reachable.
    static let reachJS = #"""
        {
        const say = e => {
          let t = e.getAttribute('aria-label') || e.getAttribute('title')
            || (e.innerText || '').replace(/\s+/g, ' ').trim();
          if (t.length > 60) t = t.slice(0, 60) + '…';
          const what = (e.getAttribute('role') || e.localName) + (e.id ? '#' + e.id : '');
          return what + (t ? ' ' + JSON.stringify(t) : '');
        };
        if (el.matches(':disabled') || el.closest('[inert]')) throw new Error(ref + ' is disabled: nothing was done');
        if (!el.getClientRects().length || el.checkVisibility && !el.checkVisibility({visibilityProperty: true})) {
          throw new Error(ref + ' is hidden: nothing was done');
        }
        const r = [...el.getClientRects()].find(r => r.width && r.height);
        if (r) {
          const root = el.getRootNode().elementFromPoint ? el.getRootNode() : el.ownerDocument;
          const hit = root.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          const field = n => n && (n.localName === 'input' || n.localName === 'textarea' || n.isContentEditable);
          const label = hit && hit.closest('label');
          const mine = !hit || el.contains(hit) || hit.contains(el)
            || label && (label.control === el || label.contains(el)) || editable && field(el) && field(hit);
          if (!mine) {
            let over = hit;
            for (let e = hit; e && e !== el.ownerDocument.body; e = e.parentElement) {
              if (e.localName === 'dialog' || /dialog|alert|banner/.test(e.getAttribute('role') || '')
                || e.getAttribute('aria-modal') || e.getAttribute('aria-label') || e.id) { over = e; break; }
            }
            throw new Error(ref + ' is under ' + say(over)
              + ': nothing was done. Close or answer that first (its button, or press Escape)');
          }
        }
        }
        """#

    /// The agent's pointer glides to `el` from where it last was, then a glow closes in on it, so the user watching
    /// sees what the agent is about to click or type in; the action waits for both when the page is on screen (a link's
    /// page would replace them at once). The pointer fades when the agent stops.
    static let flashJS = #"""
        {
        const fr = box(el), on = document.visibilityState === 'visible';
        const to = [fr.left + fr.width / 2, fr.top + Math.min(fr.height / 2, 20)];
        let cur = document.querySelector('[data-kelp-flash="cursor"]');
        if (!cur) {
          const ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg'), path = document.createElementNS(ns, 'path');
          svg.setAttribute('width', '22'); svg.setAttribute('height', '22');
          path.setAttribute('d', 'M3 2 L3 18 L7.5 14 L10.5 20.5 L13 19.3 L10 13 L16 13 Z');
          path.setAttribute('stroke', '#fff'); path.setAttribute('stroke-width', '1.5'); path.setAttribute('stroke-linejoin', 'round');
          svg.append(path); cur = document.createElement('div'); cur.append(svg);
          cur.setAttribute('data-kelp-flash', 'cursor');
          cur.style.cssText = 'position:fixed;left:0;top:0;pointer-events:none;z-index:2147483647;filter:drop-shadow(0 1px 2px rgba(0,0,0,.4))';
          document.documentElement.appendChild(cur);
        }
        cur.querySelector('path').setAttribute('fill', accent);
        cur.getAnimations().forEach(a => a.cancel());
        const from = window.__kelpAt || [to[0] + 60, to[1] + 60], at = p => 'translate(' + (p[0] - 3) + 'px,' + (p[1] - 2) + 'px)';
        window.__kelpAt = to; cur.style.transform = at(to);
        const move = cur.animate([{transform: at(from)}, {transform: at(to)}], {duration: motion.appear, easing: 'ease-in-out'});
        clearTimeout(window.__kelpHide);
        window.__kelpHide = setTimeout(() => cur.animate([{opacity: 1}, {opacity: 0}], {duration: motion.disappear, fill: 'forwards'}), motion.idle);
        if (on) await move.finished.catch(() => 0);
        const fl = document.createElement('div');
        fl.setAttribute('data-kelp-flash', '');
        fl.style.cssText = 'position:fixed;box-sizing:border-box;pointer-events:none;z-index:2147483647;border-radius:8px;'
          + 'left:' + (fr.left - 4) + 'px;top:' + (fr.top - 4) + 'px;width:' + (fr.width + 8) + 'px;height:' + (fr.height + 8) + 'px;'
          + 'border:2px solid ' + accent + ';background:' + accent + '26;'
          + 'box-shadow:0 0 0 4px ' + accent + '4d,0 0 18px 6px ' + accent + '99';
        document.documentElement.appendChild(fl);
        fl.animate([{opacity: 0, transform: 'scale(1.3)'}, {opacity: 1, transform: 'scale(1)'}], {duration: motion.appear, easing: 'ease-out'});
        // Removed by the clock: a page off screen plays no animation, so one's end would never come.
        setTimeout(() => { fl.animate([{opacity: 1}, {opacity: 0}], {duration: motion.disappear, fill: 'forwards'});
          setTimeout(() => fl.remove(), motion.disappear); }, motion.flash);
        if (on) await new Promise(r => setTimeout(r, motion.lead));
        }
        """#

    /// Before a screenshot: no outline of ours, finite animations done (a dialog closing), and a frame drawn.
    static let calmJS = #"""
        try {
          document.querySelectorAll('[data-kelp-flash]').forEach(e => e.remove());
          const wait = ms => new Promise(r => setTimeout(r, ms));
          const finite = document.getAnimations().filter(a => a.playState === 'running' && a.effect && a.effect.getComputedTiming().endTime !== Infinity);
          await Promise.race([Promise.all(finite.map(a => a.finished.catch(() => 0))), wait(1500)]);
          await Promise.race([new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))), wait(150)]);
        } catch (_) {}
        """#

    /// What a mouse click sends: pointer and mouse down, focus, up, then click (which follows a link, ticks a box,
    /// submits).
    static let clickJS = #"""
        const r = el.getBoundingClientRect(), view = el.ownerDocument.defaultView;
        const o = {bubbles: true, cancelable: true, composed: true, view, button: 0, clientX: r.left + r.width / 2,
          clientY: r.top + r.height / 2};
        const p = {...o, pointerId: 1, pointerType: 'mouse', isPrimary: true};
        el.dispatchEvent(new PointerEvent('pointerdown', p)); el.dispatchEvent(new MouseEvent('mousedown', o));
        if (el.focus) el.focus({preventScroll: true});
        el.dispatchEvent(new PointerEvent('pointerup', p)); el.dispatchEvent(new MouseEvent('mouseup', o));
        el.click();
        """#

    /// Replaces the field's text the way typing does: a key at a time (keydown, the value through its own setter so
    /// frameworks that wrap it, as React does, see it, input, keyup), so masks and suggestions follow and the user sees
    /// it typed; then `change`. A key the page cancels isn't typed. Fields whose half-typed value isn't one (date,
    /// number, colour) take the whole text at once, and one it isn't in their format is refused; a select takes an
    /// option by its text or value (any case), or the one option its text starts with. `submit` presses Enter. Returns
    /// what the field shows then (a password: the text typed).
    static let typeJS = #"""
        el.focus();
        const wait = ms => new Promise(r => setTimeout(r, ms));
        const delay = document.visibilityState === 'visible' ? Math.min(motion.key, motion.typing / Math.max(1, text.length)) : 0;
        const typed = el.isContentEditable || el.localName === 'textarea'
          || el.localName === 'input' && ['text', 'search', 'email', 'url', 'tel', 'password'].includes(el.type);
        const V = el.ownerDocument.defaultView;
        const proto = el.localName === 'textarea' ? V.HTMLTextAreaElement.prototype
          : el.localName === 'select' ? V.HTMLSelectElement.prototype : V.HTMLInputElement.prototype;
        const set = v => Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);
        const FORMAT = {date: 'YYYY-MM-DD', time: 'HH:MM', 'datetime-local': 'YYYY-MM-DDTHH:MM', month: 'YYYY-MM',
          week: 'YYYY-W05', number: 'a number', color: '#rrggbb'};
        const option = want => {
          const n = s => String(s).replace(/\s+/g, ' ').trim().toLowerCase();
          const opts = [...el.options].filter(o => !o.disabled);
          const starts = opts.filter(o => n(o.text).startsWith(n(want)));
          const o = opts.find(o => o.value === want || n(o.text) === n(want))
            || (starts.length === 1 ? starts[0] : null);
          if (o) return o;
          const list = (starts.length > 1 ? starts : opts).slice(0, 40)
            .map(o => JSON.stringify(o.text.trim())).join(', ');
          throw new Error((starts.length > 1 ? 'More than one option of ' + ref + ' starts with ' : 'No option ')
            + JSON.stringify(want) + (starts.length > 1 ? ': ' : ' in ' + ref + ': ') + list);
        };
        if (!typed) {
          const v = el.localName === 'select' ? option(text).value : text, old = el.value;
          set(v);
          if (FORMAT[el.type] && v && !el.value) {
            set(old);
            throw new Error(ref + ' takes ' + FORMAT[el.type] + ', not ' + JSON.stringify(v));
          }
          el.dispatchEvent(new Event('input', {bubbles: true}));
        } else {
          const doc = el.ownerDocument;
          if (el.isContentEditable) { doc.execCommand('selectAll'); doc.execCommand('delete'); }
          else if (el.value) { set(''); el.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'deleteContentBackward'})); }
          for (const ch of text) {
            const k = {key: ch === '\n' ? 'Enter' : ch, bubbles: true, cancelable: true, composed: true};
            if (el.dispatchEvent(new KeyboardEvent('keydown', k)) && el.dispatchEvent(new KeyboardEvent('keypress', k))) {
              if (el.isContentEditable) doc.execCommand('insertText', false, ch);
              else if (!(el.maxLength > 0 && el.value.length >= el.maxLength)) {
                set(el.value + ch); el.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: ch}));
              }
            }
            el.dispatchEvent(new KeyboardEvent('keyup', k));
            if (delay >= 4) await wait(delay);
          }
        }
        el.dispatchEvent(new Event('change', {bubbles: true}));
        if (submit) {
          const k = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true};
          const go = el.dispatchEvent(new KeyboardEvent('keydown', k));
          el.dispatchEvent(new KeyboardEvent('keypress', k)); el.dispatchEvent(new KeyboardEvent('keyup', k));
          if (go && el.form && el.localName !== 'textarea') el.form.requestSubmit();
        }
        if (el.type === 'password') return text;
        if (el.isContentEditable) return el.innerText.trim();
        return el.localName === 'select' ? (el.selectedOptions[0] || {text: ''}).text.trim() : el.value;
        """#

    /// `files` ({name, type, data in base64}) into the file field `el` is, holds or labels (or the page's only one, for
    /// a styled button over a hidden field), then `input` and `change`: what choosing them in the panel does. With no
    /// field, they're dropped on `el` (a drop zone), as dragging them there from Finder does; returns "dropped" then.
    static let uploadJS = #"""
        const isFile = x => x && x.localName === 'input' && x.type === 'file';
        const all = el.ownerDocument.querySelectorAll('input[type=file]');
        const input = [el, el.control, el.querySelector('input[type=file]'), all.length === 1 ? all[0] : null].find(isFile);
        const dt = new DataTransfer();
        for (const f of files) {
          const bin = atob(f.data), bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          dt.items.add(new File([bytes], f.name, {type: f.type}));
        }
        if (!input) {
          const r = el.getBoundingClientRect(), view = el.ownerDocument.defaultView;
          const o = {bubbles: true, cancelable: true, composed: true, view, dataTransfer: dt,
            clientX: r.left + r.width / 2, clientY: r.top + r.height / 2};
          el.dispatchEvent(new DragEvent('dragenter', o));
          if (el.dispatchEvent(new DragEvent('dragover', o))) {
            el.dispatchEvent(new DragEvent('dragleave', o));
            throw new Error(ref + ' is no file field and takes no files dropped on it: give the ref of an '
              + '<input type=file>, its label, the button over it, or the zone files are dropped on');
          }
          el.dispatchEvent(new DragEvent('drop', o));
          return 'dropped';
        }
        if (files.length > 1 && !input.multiple) throw new Error('This field takes one file');
        input.files = dt.files;
        input.dispatchEvent(new Event('input', {bubbles: true})); input.dispatchEvent(new Event('change', {bubbles: true}));
        return 'chosen';
        """#

    /// `el` dragged onto the element of `onto` (a ref, or a selector for a zone with none), as a person drags: pressed,
    /// moved there in steps, let go. What the page makes draggable when pressed (`draggable`: lists, boards, files)
    /// gets the drag events a browser sends, and the element under the pointer must take the drop (its `dragover`
    /// cancelled), as in a browser; anything else follows the pointer (sortable lists by pointer, sliders, canvases).
    static let dragJS = #"""
        const byRef = /^e\d+$/.test(onto);
        const dst = byRef ? window.__kelpRefs.get(onto) : el.ownerDocument.querySelector(onto);
        if (!dst || !dst.isConnected) {
          throw new Error('No ' + onto + ' on the page now' + (byRef ? ': take a new snapshot' : ''));
        }
        const doc = el.ownerDocument, view = doc.defaultView;
        if (dst.ownerDocument !== doc) {
          throw new Error(ref + ' and ' + onto + ' are in different frames: drag within one');
        }
        const wait = ms => new Promise(r => setTimeout(r, ms));
        const mid = e => {
          const r = [...e.getClientRects()].find(r => r.width && r.height) || e.getBoundingClientRect();
          return [r.left + r.width / 2, r.top + r.height / 2];
        };
        dst.scrollIntoView({block: 'nearest', inline: 'nearest'});
        const from = mid(el), end = mid(dst), STEPS = 10;
        const step = i => [from[0] + (end[0] - from[0]) * i / STEPS, from[1] + (end[1] - from[1]) * i / STEPS];
        const under = p => doc.elementFromPoint(p[0], p[1]) || dst;
        const point = (t, type, p, buttons) => {
          const o = {bubbles: true, cancelable: true, composed: true, view, clientX: p[0], clientY: p[1], screenX: p[0],
            screenY: p[1], button: 0, buttons, pointerId: 1, pointerType: 'mouse', isPrimary: true};
          t.dispatchEvent(new PointerEvent('pointer' + type, o)); t.dispatchEvent(new MouseEvent('mouse' + type, o));
        };
        point(el, 'down', from, 1);
        await wait(0);
        const drag = el.closest('[draggable="true"]');
        if (drag) {
          const dt = new DataTransfer();
          const fire = (t, type, p) => t.dispatchEvent(new DragEvent(type, {bubbles: true, cancelable: true,
            composed: true, view, clientX: p[0], clientY: p[1], dataTransfer: dt}));
          if (!fire(drag, 'dragstart', from)) throw new Error('The page didn\'t let ' + ref + ' be dragged');
          let over = null, took = false;
          for (let i = 1; i <= STEPS; i++) {
            const p = step(i), t = under(p);
            fire(drag, 'drag', p);
            if (t !== over) { if (over) fire(over, 'dragleave', p); fire(t, 'dragenter', p); over = t; }
            took = !fire(t, 'dragover', p);
            await wait(16);
          }
          if (took) fire(over, 'drop', end); else fire(over, 'dragleave', end);
          fire(drag, 'dragend', end);
          if (!took) throw new Error(onto + " doesn't take what " + ref + ' drags: the page refused the drop there');
        } else {
          for (let i = 1; i <= STEPS; i++) {
            const p = step(i);
            point(under(p), 'move', p, 1);
            await wait(16);
          }
          point(under(end), 'up', end, 0);
        }
        """#

    /// `text` shown on the page (as a person sees it: transparent text isn't, a frame of the site's own is), `selector`
    /// on it.
    static var waitJS: String { shownTextJS + waitBody }
    private static let waitBody = #"""
        if (selector && !document.querySelector(selector)) return false;
        if (!text) return true;
        const roots = [document], seen = [];
        for (let i = 0; i < roots.length; i++) {
          const walk = document.createTreeWalker(roots[i], NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
          for (let n = walk.nextNode(); n; n = walk.nextNode()) {
            if (n.nodeType === 1) {
              if (n.shadowRoot) roots.push(n.shadowRoot);
              let d = null; try { d = n.contentDocument; } catch (_) {}
              if (d) roots.push(d);
            } else if (n.textContent.trim() && textShown(n.parentElement)) seen.push(n.textContent);
          }
        }
        const norm = s => s.replace(/\s+/g, ' ').trim();
        return norm(seen.join(' ')).includes(norm(text));
        """#

    /// What the pointer moving onto `el` sends: menus that open from script do; a CSS `:hover` doesn't follow events.
    static let hoverJS = #"""
        const r = el.getBoundingClientRect(), view = el.ownerDocument.defaultView;
        const o = {bubbles: true, cancelable: true, composed: true, view, clientX: r.left + r.width / 2,
          clientY: r.top + r.height / 2};
        const p = {...o, pointerId: 1, pointerType: 'mouse', isPrimary: true};
        el.dispatchEvent(new PointerEvent('pointerover', p)); el.dispatchEvent(new PointerEvent('pointerenter', {...p, bubbles: false}));
        el.dispatchEvent(new MouseEvent('mouseover', o)); el.dispatchEvent(new MouseEvent('mouseenter', {...o, bubbles: false}));
        el.dispatchEvent(new PointerEvent('pointermove', p)); el.dispatchEvent(new MouseEvent('mousemove', o));
        """#

    /// A key (`Escape`, `Shift+Tab`, `ArrowDown`, `a`) on the focused element (in a shadow root or a frame of the
    /// site's own too), or on `ref` once it's focused. Events from a script do nothing by themselves, so what the
    /// browser would do follows unless the page prevented it: Tab moves the focus, Enter clicks a link or button or
    /// submits a field's form, Space clicks a button or a box.
    static let pressJS = #"""
        const deep = () => {
          let a = document.activeElement;
          for (;;) {
            let d = null; try { d = a && a.contentDocument; } catch (_) {}
            if (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
            else if (d && d.activeElement) a = d.activeElement;
            else return a || document.body;
          }
        };
        let el = deep();
        if (ref) {
          const r = window.__kelpRefs && window.__kelpRefs.get(ref);
          if (!r || !r.isConnected) throw new Error('No ' + ref + ' on the page now: take a new snapshot');
          r.focus(); el = r;
        }
        const parts = key.split('+'), name = parts.pop(), mods = new Set(parts.map(m => m.toLowerCase()));
        const NAMED = {Enter: 13, Escape: 27, Esc: 27, Tab: 9, Backspace: 8, Delete: 46, Space: 32, ArrowLeft: 37, ArrowUp: 38,
          ArrowRight: 39, ArrowDown: 40, PageUp: 33, PageDown: 34, Home: 36, End: 35};
        const k = name === 'Esc' ? 'Escape' : name === 'Space' ? ' ' : name;
        const keyCode = NAMED[name] || (k.length === 1 ? k.toUpperCase().charCodeAt(0) : 0);
        if (!keyCode) throw new Error('No key ' + name + ': Enter, Escape, Tab, Backspace, Delete, Space, an arrow, PageUp, PageDown, Home, End or one character');
        const code = NAMED[name] ? (name === 'Esc' ? 'Escape' : name) : /[a-z]/i.test(k) ? 'Key' + k.toUpperCase() : /[0-9]/.test(k) ? 'Digit' + k : k;
        const o = {key: k, code, keyCode, which: keyCode, bubbles: true, cancelable: true, composed: true, shiftKey: mods.has('shift'),
          ctrlKey: mods.has('ctrl') || mods.has('control'), altKey: mods.has('alt') || mods.has('option'),
          metaKey: mods.has('meta') || mods.has('cmd') || mods.has('command')};
        const go = el.dispatchEvent(new KeyboardEvent('keydown', o));
        if (go && k.length === 1) el.dispatchEvent(new KeyboardEvent('keypress', o));
        const button = el.localName === 'button' || el.getAttribute('role') === 'button';
        if (go && k === 'Tab') {
          const FOCUS = 'a[href],button,input,select,textarea,[tabindex],[contenteditable]';
          const all = [...el.ownerDocument.querySelectorAll(FOCUS)]
            .filter(e => e.tabIndex >= 0 && !e.disabled && e.getClientRects().length);
          const next = all[(all.indexOf(el) + (o.shiftKey ? -1 : 1) + all.length) % all.length];
          if (next) next.focus();
        } else if (go && k === 'Enter') {
          if (el.localName === 'a' || button) el.click();
          else if (el.form && el.localName === 'input') el.form.requestSubmit();
        } else if (go && k === ' ' && (button || el.type === 'checkbox' || el.type === 'radio')) el.click();
        (deep() || el).dispatchEvent(new KeyboardEvent('keyup', o));
        """#

    /// Scrolls the page, or the biggest box that scrolls when the page itself doesn't (an app's main pane), by most of
    /// a screen, to an end, or `ref` into view; then waits a little for what scrolling loads. Says where it is.
    static let scrollJS = #"""
        if (/^e\d+$/.test(to)) {
          const el = window.__kelpRefs && window.__kelpRefs.get(to);
          if (!el || !el.isConnected) throw new Error('No ' + to + ' on the page now: take a new snapshot');
          el.scrollIntoView({block: 'center'});
        } else {
          let s = document.scrollingElement || document.documentElement;
          if (s.scrollHeight <= s.clientHeight + 1) for (const e of document.querySelectorAll('*')) {
            if (e.scrollHeight <= e.clientHeight + 1 || e.clientHeight < 100) continue;
            const y = getComputedStyle(e).overflowY;
            if ((y === 'auto' || y === 'scroll') && (s === document.scrollingElement || e.clientHeight * e.clientWidth > s.clientHeight * s.clientWidth)) s = e;
          }
          const h = s.clientHeight;
          if (to === 'down') s.scrollBy(0, h * 0.8); else if (to === 'up') s.scrollBy(0, -h * 0.8);
          else if (to === 'top') s.scrollTo(0, 0); else if (to === 'bottom') s.scrollTo(0, s.scrollHeight);
          else throw new Error('scroll down, up, top, bottom or to a ref');
        }
        await new Promise(r => setTimeout(r, 300));
        const s = document.scrollingElement || document.documentElement;
        return Math.round(s.scrollTop) + ' of ' + Math.max(0, s.scrollHeight - s.clientHeight);
        """#
}
