import AppKit
import Core
import DesignKit
import WebKit
import WorkbenchKit

/// `kelp browser`: what an agent does on the page. Kelp's scripts run in a world of their own (`world`): the page can't see
/// or change them, but they see its DOM. Clicks and typing are DOM events (`isTrusted` false), so they work while the tab
/// isn't on screen. Limit: a page that only listens to trusted events ignores them; send AppKit events when one matters.
extension BrowserTab {
    static let world = WKContentWorld.world(name: "kelp.browser")

    func browse(_ action: String, _ args: JSONValue) async throws -> JSONValue {
        func need(_ key: String) throws -> String {
            guard let value = args[key]?.string, !value.isEmpty else {
                throw RPCError.invalidParams("\(action) needs \(key)")
            }
            return value
        }
        // The user's logged-in tab is the agent's on the one site the user allowed: taken elsewhere since (by the user, once
        // the agent left it), it's theirs.
        if !agent, let now = web.url, now.scheme != "about", PageOrigin.of(now) != PageOrigin.of(URL(string: start)) {
            throw RPCError.invalidParams(
                "This tab is on another site than the one the user let you use: kelp browser open <url> --shared asks again."
            )
        }
        watch()
        sized()
        drivenAt = Date()
        // Taken over, the user may be signing in: what the page holds now (fields, pixels, requests) is theirs.
        if takenOver, !Self.whileTakenOver.contains(action) {
            throw RPCError.internalError("The user took this page over: only wait and info until they hand it back")
        }
        switch action {
        case "console", "network": return .string(listed(action == "console", clear: args["clear"]?.bool == true))
        case "info": return try await settled()
        case "open":
            // The page it shows already: an agent opens it again after changing the code, so nothing comes from the cache
            // (a dev server that doesn't ask for revalidation would hand back the old script).
            let url = try need("url")
            if let now = web.url?.absoluteString, Self.same(now, url) { web.reloadFromOrigin() } else { load(url) }
            return try await settled()
        case "reload":
            web.reloadFromOrigin()
            return try await settled()
        case "viewport": return try await resize(try need("size"))
        case "snapshot":
            let find = args["find"]?.string ?? ""
            let text =
                try await run(Self.snapshotJS, ["ref": args["ref"]?.string ?? "", "max": find.isEmpty ? 1500 : 20000])
                as? String ?? ""
            return .string(find.isEmpty ? text : Self.found(find, in: text))
        case "dialog":
            let accept = try need("answer") == "accept", text = accept ? args["text"]?.string : nil
            dialogAnswer = (accept, text)
            guard accept else { return .string("The page's next question gets Cancel") }
            return .string("The page's next question gets OK" + (text.map { " and \"\($0)\"" } ?? ""))
        case "upload":
            // The CLI read them: the agent's files, as it sees them (the app touches no project file itself).
            let files = (args["files"]?.array ?? []).compactMap { file -> [String: String]? in
                if case .object(let fields) = file { return fields.compactMapValues(\.string) } else { return nil }
            }
            guard !files.isEmpty else { throw RPCError.invalidParams("upload needs a file") }
            _ = try await run(
                Self.findJS + Self.flashJS + Self.uploadJS, shown(["ref": try need("ref"), "files": files]))
            return try await settled()
        case "click", "hover":
            _ = try await run(
                Self.findJS + Self.flashJS + (action == "click" ? Self.clickJS : Self.hoverJS),
                shown(["ref": try need("ref")]))
            return try await settled()
        case "type":
            _ = try await run(
                Self.findJS + Self.flashJS + Self.typeJS,
                shown([
                    "ref": try need("ref"), "text": args["text"]?.string ?? "",
                    "submit": args["submit"]?.bool == true
                ]))
            return try await settled()
        case "press":
            _ = try await run(Self.pressJS, ["key": try need("key"), "ref": args["ref"]?.string ?? ""])
            return try await settled()
        case "scroll":
            let at = try await run(Self.scrollJS, ["to": args["to"]?.string ?? "down"]) as? String ?? ""
            return try await settled(["scroll": .string(at)])
        case "back":
            guard web.canGoBack else { throw RPCError.invalidParams("No page to go back to.") }
            web.goBack()
            return try await settled()
        case "eval":
            // The page's own world: the agent asks about the page's state (its globals, its framework).
            // A promise that never settles ends here, before the daemon stops waiting: nothing is left awaiting it.
            let limit = Int(UIBrowser.wait - 10) * 1000
            let body =
                "const v = await Promise.race([(\n\(try need("js"))\n), new Promise((_, no) => setTimeout(() => "
                + "no(new Error('No answer from the script in \(limit / 1000) s')), \(limit)))]);\n"
                + "return v === undefined ? 'null' : (JSON.stringify(v) ?? 'null');"
            let text = try await run(body, page: true) as? String ?? "null"
            let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
            // The CLI prints nothing for null: the agent couldn't tell it ran.
            return value == .null ? .string("null") : value
        case "screenshot":
            _ = try await run(Self.calmJS)   // what an action started has played out and been drawn
            let image: NSImage
            do { image = try await web.takeSnapshot(configuration: nil) } catch {
                throw RPCError.internalError(
                    "No screenshot: \(error.localizedDescription) Show the page's tab and try again.")
            }
            guard let path = Self.savePNG(image, kind: "page", to: args["path"]?.string) else {
                throw RPCError.internalError("Couldn't write the screenshot")
            }
            return .object(["path": .string(path)])
        case "wait":
            let text = args["text"]?.string, selector = args["selector"]?.string
            let seconds = min(args["timeout"]?.number ?? 10, UIBrowser.wait - 5),
                end = Date().addingTimeInterval(seconds)
            while try await run(Self.waitJS, ["text": text ?? "", "selector": selector ?? ""]) as? Bool != true {
                guard Date() < end else {
                    throw RPCError.internalError("Not on the page after \(Int(seconds)) s: \(text ?? selector ?? "")")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            // What's left of the daemon's wait: an answer after it would find nobody waiting.
            return try await settled(within: min(30, max(1, UIBrowser.wait - 5 - seconds + end.timeIntervalSinceNow)))
        default: throw RPCError.invalidParams("kelp browser knows no \(action)")
        }
    }

    /// A page no pane shows (a tab behind another, a workspace not on screen) has no size, and one with none lays nothing
    /// out: no text to read, nothing to click. It gets the agent's viewport, else a laptop window's size, until a pane shows it.
    private func sized() {
        guard web.window == nil else { return }
        if let viewport {
            web.frame = CGRect(origin: .zero, size: viewport)
            return
        }
        guard web.frame.width < 200 || web.frame.height < 200 else { return }
        web.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /// `viewport 390x844`: the page at that size (`reset`: the pane's), and the size the page now says it has.
    private func resize(_ size: String) async throws -> JSONValue {
        if size == "reset" {
            viewport = nil
            if web.window == nil { web.frame = .zero }
        } else {
            let wh = size.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" }).compactMap { Int($0) }
            guard wh.count == 2, (200...4000).contains(wh[0]), (200...4000).contains(wh[1]) else {
                throw RPCError.invalidParams("viewport takes WIDTHxHEIGHT, 200 to 4000 each (390x844), or reset")
            }
            viewport = CGSize(width: wh[0], height: wh[1])
        }
        if web.window == nil { sized() } else { view.layoutSubtreeIfNeeded() }   // off screen, layout would size it to nothing
        // A timer, not a frame: a page off screen draws none.
        let now = try await run("await new Promise(r => setTimeout(r, 100)); return innerWidth + 'x' + innerHeight")
        return try await settled(["viewport": .string(now as? String ?? "")])
    }

    /// What an agent may still do on a page the user took over: look.
    static let whileTakenOver: Set = ["wait", "info"]

    /// The snapshot's lines that mention `text` (any case), each under the lines it sits in, so a ref keeps its place.
    nonisolated static func found(_ text: String, in snapshot: String) -> String {
        let lines = snapshot.components(separatedBy: "\n")
        guard let head = lines.first else { return "" }
        var keep = IndexSet()
        for (index, line) in lines.enumerated().dropFirst() where line.localizedCaseInsensitiveContains(text) {
            keep.insert(index)
            var depth = line.prefix { $0 == " " }.count
            for above in stride(from: index - 1, to: 0, by: -1) where depth > 0 {
                let indent = lines[above].prefix { $0 == " " }.count
                if indent < depth {
                    keep.insert(above)
                    depth = indent
                }
            }
        }
        return keep.isEmpty
            ? head + "\nNothing on the page mentions \"\(text)\"."
            : ([head] + keep.map { lines[$0] }).joined(separator: "\n")
    }

    /// Two spellings of one address: `http://localhost:3000` and `http://localhost:3000/`.
    static func same(_ first: String, _ second: String) -> Bool {
        func bare(_ address: String) -> String { address.hasSuffix("/") ? String(address.dropLast()) : address }
        return bare(first) == bare(second)
    }

    /// Where the page is once what an action started has loaded (a click that navigates); a load that fails says why.
    private func settled(_ extra: [String: JSONValue] = [:], within: TimeInterval = 30) async throws -> JSONValue {
        try await Task.sleep(for: .milliseconds(150))   // a navigation the action started has begun
        let end = Date().addingTimeInterval(within)
        // A download the action started is waited for too, so its answer says where the file is.
        while web.isLoading || !downloading.isEmpty, Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        var answer = extra.merging(["url": .string(web.url?.absoluteString ?? ""), "title": .string(web.title ?? "")]) {
            $1
        }
        if web.isLoading { answer["loading"] = .bool(true) }
        if !dialogs.isEmpty {
            answer["dialogs"] = .array(dialogs.map(JSONValue.string))
            dialogs = []
        }
        if !downloads.isEmpty {
            answer["downloads"] = .array(downloads.map(JSONValue.string))
            downloads = []
        }
        if let loadError { answer["error"] = .string(loadError) }
        return .object(answer)
    }

    /// The arguments of an action the user sees done: the element's glow, in the accent colour and Kelp's motion (ms).
    /// The wait before the action, the typing pace and how long the pointer stays aren't motion: Reduce Motion keeps them.
    private func shown(_ args: [String: Any]) -> [String: Any] {
        let ms = { (seconds: TimeInterval) in Int(seconds * 1000) }
        let motion = [
            "appear": ms(Motion.duration(Motion.appear)), "disappear": ms(Motion.duration(Motion.disappear)),
            "flash": ms(Motion.flash), "lead": ms(Motion.appear + Motion.fast), "idle": ms(Motion.wait),
            "key": ms(Motion.stagger), "typing": ms(Motion.linger)
        ]
        return args.merging(["accent": NSColor.themeAccent.hexString, "motion": motion]) { $1 }
    }

    /// An async function body with `args` as its variables; a script's exception comes back as its message.
    private func run(_ body: String, _ args: [String: Any] = [:], page: Bool = false) async throws -> Any? {
        do {
            return try await web.callAsyncJavaScript(
                body, arguments: args, in: nil, contentWorld: page ? .page : Self.world)
        } catch let error as NSError where error.userInfo["WKJavaScriptExceptionMessage"] != nil {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            throw RPCError.internalError(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
        }
    }

    /// The page as an accessibility tree, a line an element: role, name, state, and a ref (`e12`) for what can be clicked
    /// or typed in. Refs are kept in Kelp's world until the next snapshot. Elements without a role don't show, their
    /// children do, one level up; links, buttons and fields show their text, not what's inside them.
    static let snapshotJS = #"""
        const old = window.__kelpRefs, root = ref ? old && old.get(ref) : document.body;
        if (ref && (!root || !root.isConnected)) throw new Error('No ' + ref + ' on the page now: take a new snapshot');
        const refs = new Map(); window.__kelpRefs = refs; let n = 0; const out = [], MAX = max;
        const ACT = new Set(['link','button','textbox','searchbox','checkbox','radio','combobox','listbox','slider','switch','tab',
          'menuitem','menuitemcheckbox','menuitemradio','option','spinbutton','treeitem','clickable']);
        const LEAF = new Set(['link','button','textbox','searchbox','checkbox','radio','combobox','slider','switch','tab','menuitem',
          'option','spinbutton','img','heading','clickable']);
        const FIELD = new Set(['textbox','searchbox','combobox','slider','spinbutton']);
        // One with buttons, links or fields inside (a card that's a link, a menu opened by hover) lists them, each with a ref.
        const INNER = 'a[href],button,input,select,textarea,[role=button],[role=link],[role=menuitem],[role=checkbox],[role=tab]';
        const leaf = (el, role) => LEAF.has(role) && (FIELD.has(role) || !el.querySelector(INNER));
        const clean = s => (typeof s === 'string' ? s : '').replace(/\s+/g, ' ').trim();
        const cut = s => (s = s || '').length > 100 ? s.slice(0, 100) + '…' : s;
        const SKIP = new Set(['script','style','noscript','template','head','svg','iframe']);
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
          const cs = getComputedStyle(el);
          if (cs.cursor === 'pointer' && !(el.parentElement && getComputedStyle(el.parentElement).cursor === 'pointer')) return 'clickable';
          return null;
        };
        const nameOf = (el, role) => {
          const l = el.getAttribute('aria-label'); if (l) return clean(l);
          const by = el.getAttribute('aria-labelledby');
          if (by) { const s = clean(by.split(/\s+/).map(id => (document.getElementById(id) || {}).innerText || '').join(' ')); if (s) return s; }
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
        const walk = (nodes, depth) => {
          for (const node of nodes) {
            if (out.length >= MAX) return;
            const pad = '  '.repeat(depth);
            if (node.nodeType === 3) { const t = clean(node.textContent); if (t) out.push(pad + '- text: ' + JSON.stringify(cut(t))); continue; }
            if (node.nodeType !== 1 || SKIP.has(node.localName) || !shown(node)) continue;
            const el = node, role = roleOf(el);
            if (!role) { walk(kids(el), depth); continue; }
            let line = pad + '- ' + role;
            const name = nameOf(el, role); if (name) line += ' ' + JSON.stringify(cut(name));
            if (role === 'heading') line += ' [level=' + (el.getAttribute('aria-level') || el.localName.slice(1)) + ']';
            if (el.checked || el.getAttribute('aria-checked') === 'true') line += ' [checked]';
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' [disabled]';
            const ex = el.getAttribute('aria-expanded'); if (ex) line += ' [expanded=' + ex + ']';
            if (ACT.has(role)) { const ref = 'e' + (++n); refs.set(ref, el); line += ' [ref=' + ref + ']'; }
            if (role === 'link' && el.getAttribute('href')) line += ' -> ' + cut(el.getAttribute('href'));
            if (FIELD.has(role)) {
              // A password's value never leaves the page: that one is typed says enough.
              const v = el.type === 'password' ? (el.value ? '••••••' : '')
                : clean(el.isContentEditable ? el.innerText : el.localName === 'select' ? (el.selectedOptions[0] || {}).text : el.value);
              if (v) line += ': ' + JSON.stringify(cut(v));
            }
            out.push(line);
            if (!leaf(el, role)) walk(kids(el), depth + 1);
          }
        };
        walk(root ? [root] : [], 0);
        return '- page ' + JSON.stringify(document.title) + ' ' + location.href + '\n' + out.join('\n')
          + (out.length >= MAX ? '\n… cut at ' + MAX + ' lines' : '');
        """#

    /// `el`: the element of `ref` from the last snapshot, scrolled into view.
    static let findJS = #"""
        const el = window.__kelpRefs && window.__kelpRefs.get(ref);
        if (!el || !el.isConnected) throw new Error('No ' + ref + ' on the page now: take a new snapshot');
        el.scrollIntoView({block: 'center', inline: 'center'});
        """#

    /// The agent's pointer glides to `el` from where it last was, then a glow closes in on it, so the user watching sees
    /// what the agent is about to click or type in; the action waits for both when the page is on screen (a link's page
    /// would replace them at once). The pointer fades when the agent stops.
    static let flashJS = #"""
        const fr = el.getBoundingClientRect(), on = document.visibilityState === 'visible';
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

    /// What a mouse click sends: pointer and mouse down, focus, up, then click (which follows a link, ticks a box, submits).
    static let clickJS = #"""
        const r = el.getBoundingClientRect();
        const o = {bubbles: true, cancelable: true, composed: true, view: window, button: 0, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2};
        const p = {...o, pointerId: 1, pointerType: 'mouse', isPrimary: true};
        el.dispatchEvent(new PointerEvent('pointerdown', p)); el.dispatchEvent(new MouseEvent('mousedown', o));
        if (el.focus) el.focus({preventScroll: true});
        el.dispatchEvent(new PointerEvent('pointerup', p)); el.dispatchEvent(new MouseEvent('mouseup', o));
        el.click();
        """#

    /// Replaces the field's text the way typing does: a key at a time (keydown, the value through its own setter so
    /// frameworks that wrap it, as React does, see it, input, keyup), so masks and suggestions follow and the user sees
    /// it typed; then `change`. A key the page cancels isn't typed. Fields whose half-typed value isn't one (date, number,
    /// colour) and selects take the whole text at once; a select an option's text or value. `submit` presses Enter.
    static let typeJS = #"""
        el.focus();
        const wait = ms => new Promise(r => setTimeout(r, ms));
        const delay = document.visibilityState === 'visible' ? Math.min(motion.key, motion.typing / Math.max(1, text.length)) : 0;
        const typed = el.isContentEditable || el.localName === 'textarea'
          || el.localName === 'input' && ['text', 'search', 'email', 'url', 'tel', 'password'].includes(el.type);
        const proto = el.localName === 'textarea' ? HTMLTextAreaElement.prototype
          : el.localName === 'select' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        const set = v => Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);
        if (!typed) {
          let v = text;
          if (el.localName === 'select') { const o = [...el.options].find(o => o.value === text || o.text.trim() === text); if (o) v = o.value; }
          set(v); el.dispatchEvent(new Event('input', {bubbles: true}));
        } else {
          if (el.isContentEditable) { document.execCommand('selectAll'); document.execCommand('delete'); }
          else if (el.value) { set(''); el.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'deleteContentBackward'})); }
          for (const ch of text) {
            const k = {key: ch === '\n' ? 'Enter' : ch, bubbles: true, cancelable: true, composed: true};
            if (el.dispatchEvent(new KeyboardEvent('keydown', k)) && el.dispatchEvent(new KeyboardEvent('keypress', k))) {
              if (el.isContentEditable) document.execCommand('insertText', false, ch);
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
        """#

    /// `files` ({name, type, data in base64}) into the file field `el` is, holds or labels (or the page's only one, for a
    /// styled button over a hidden field), then `input` and `change`: what choosing them in the panel does.
    static let uploadJS = #"""
        const isFile = x => x && x.localName === 'input' && x.type === 'file';
        const all = document.querySelectorAll('input[type=file]');
        const input = [el, el.control, el.querySelector('input[type=file]'), all.length === 1 ? all[0] : null].find(isFile);
        if (!input) throw new Error(ref + ' is no file field: give the ref of an <input type=file>, its label or the button over it');
        if (files.length > 1 && !input.multiple) throw new Error('This field takes one file');
        const dt = new DataTransfer();
        for (const f of files) {
          const bin = atob(f.data), bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          dt.items.add(new File([bytes], f.name, {type: f.type}));
        }
        input.files = dt.files;
        input.dispatchEvent(new Event('input', {bubbles: true})); input.dispatchEvent(new Event('change', {bubbles: true}));
        """#

    static let waitJS = #"""
        return (!selector || !!document.querySelector(selector)) && (!text || !!(document.body && document.body.innerText.includes(text)));
        """#

    /// What the pointer moving onto `el` sends: menus that open from script do; a CSS `:hover` doesn't follow events.
    static let hoverJS = #"""
        const r = el.getBoundingClientRect();
        const o = {bubbles: true, cancelable: true, composed: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2};
        const p = {...o, pointerId: 1, pointerType: 'mouse', isPrimary: true};
        el.dispatchEvent(new PointerEvent('pointerover', p)); el.dispatchEvent(new PointerEvent('pointerenter', {...p, bubbles: false}));
        el.dispatchEvent(new MouseEvent('mouseover', o)); el.dispatchEvent(new MouseEvent('mouseenter', {...o, bubbles: false}));
        el.dispatchEvent(new PointerEvent('pointermove', p)); el.dispatchEvent(new MouseEvent('mousemove', o));
        """#

    /// A key (`Escape`, `Shift+Tab`, `ArrowDown`, `a`) on the focused element, or on `ref` once it's focused. Events
    /// from a script do nothing by themselves, so what the browser would do follows unless the page prevented it:
    /// Tab moves the focus, Enter clicks a link or button or submits a field's form, Space clicks a button or a box.
    static let pressJS = #"""
        let el = document.activeElement || document.body;
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
          const all = [...document.querySelectorAll('a[href],button,input,select,textarea,[tabindex],[contenteditable]')]
            .filter(e => e.tabIndex >= 0 && !e.disabled && e.getClientRects().length);
          const next = all[(all.indexOf(el) + (o.shiftKey ? -1 : 1) + all.length) % all.length];
          if (next) next.focus();
        } else if (go && k === 'Enter') {
          if (el.localName === 'a' || button) el.click();
          else if (el.form && el.localName === 'input') el.form.requestSubmit();
        } else if (go && k === ' ' && (button || el.type === 'checkbox' || el.type === 'radio')) el.click();
        (document.activeElement || el).dispatchEvent(new KeyboardEvent('keyup', o));
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
