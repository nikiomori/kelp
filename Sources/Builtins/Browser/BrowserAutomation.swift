import AppKit
import WebKit
import Core

/// `kelp browser`: what an agent does on the page. Kelp's scripts run in a world of their own (`world`): the page can't see
/// or change them, but they see its DOM. Clicks and typing are DOM events (`isTrusted` false), so they work while the tab
/// isn't on screen. Limit: a page that only listens to trusted events ignores them; send AppKit events when one matters.
extension BrowserTab {
    static let world = WKContentWorld.world(name: "kelp.browser")

    func browse(_ action: String, _ args: JSONValue) async throws -> JSONValue {
        func need(_ k: String) throws -> String {
            guard let v = args[k]?.string, !v.isEmpty else { throw RPCError.invalidParams("\(action) needs \(k)") }
            return v
        }
        watch()
        switch action {
        case "console", "network": return .string(listed(action == "console", clear: args["clear"]?.bool == true))
        case "info": return try await settled()
        case "open": load(try need("url")); return try await settled()
        case "snapshot": return .string(try await run(Self.snapshotJS) as? String ?? "")
        case "click":
            _ = try await run(Self.findJS + Self.clickJS, ["ref": try need("ref")])
            return try await settled()
        case "type":
            _ = try await run(Self.findJS + Self.typeJS, ["ref": try need("ref"), "text": args["text"]?.string ?? "",
                                                          "submit": args["submit"]?.bool == true])
            return try await settled()
        case "eval":
            // The page's own world: the agent asks about the page's state (its globals, its framework).
            let body = "const v = await (\n\(try need("js"))\n);\nreturn v === undefined ? 'null' : (JSON.stringify(v) ?? 'null');"
            let text = try await run(body, page: true) as? String ?? "null"
            return (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
        case "screenshot":
            let image: NSImage
            do { image = try await web.takeSnapshot(configuration: nil) } catch {
                throw RPCError.internalError("No screenshot: \(error.localizedDescription) Show the page's tab and try again.")
            }
            guard let path = Self.savePNG(image, kind: "page", to: args["path"]?.string) else { throw RPCError.internalError("Couldn't write the screenshot") }
            return .object(["path": .string(path)])
        case "wait":
            let text = args["text"]?.string, selector = args["selector"]?.string
            let seconds = min(args["timeout"]?.number ?? 10, UIBrowser.wait - 5), end = Date().addingTimeInterval(seconds)
            while try await run(Self.waitJS, ["text": text ?? "", "selector": selector ?? ""]) as? Bool != true {
                guard Date() < end else { throw RPCError.internalError("Not on the page after \(Int(seconds)) s: \(text ?? selector ?? "")") }
                try await Task.sleep(for: .milliseconds(250))
            }
            return try await settled()
        default: throw RPCError.invalidParams("kelp browser knows no \(action)")
        }
    }

    /// Where the page is once what an action started has loaded (a click that navigates); a load that fails says why.
    private func settled() async throws -> JSONValue {
        try await Task.sleep(for: .milliseconds(150))   // a navigation the action started has begun
        let end = Date().addingTimeInterval(30)
        while web.isLoading, Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        var o: [String: JSONValue] = ["url": .string(web.url?.absoluteString ?? ""), "title": .string(web.title ?? "")]
        if web.isLoading { o["loading"] = .bool(true) }
        if let e = loadError { o["error"] = .string(e) }
        return .object(o)
    }

    /// An async function body with `args` as its variables; a script's exception comes back as its message.
    private func run(_ body: String, _ args: [String: Any] = [:], page: Bool = false) async throws -> Any? {
        do { return try await web.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: page ? .page : Self.world) }
        catch let e as NSError where e.userInfo["WKJavaScriptExceptionMessage"] != nil {
            let message = e.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            throw RPCError.internalError(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
        }
    }

    /// The page as an accessibility tree, a line an element: role, name, state, and a ref (`e12`) for what can be clicked
    /// or typed in. Refs are kept in Kelp's world until the next snapshot. Elements without a role don't show, their
    /// children do, one level up; links, buttons and fields show their text, not what's inside them.
    static let snapshotJS = #"""
    const refs = new Map(); window.__kelpRefs = refs; let n = 0; const out = [], MAX = 1500;
    const ACT = new Set(['link','button','textbox','searchbox','checkbox','radio','combobox','listbox','slider','switch','tab',
      'menuitem','menuitemcheckbox','menuitemradio','option','spinbutton','treeitem','clickable']);
    const LEAF = new Set(['link','button','textbox','searchbox','checkbox','radio','combobox','slider','switch','tab','menuitem',
      'option','spinbutton','img','heading','clickable']);
    const FIELD = new Set(['textbox','searchbox','combobox','slider','spinbutton']);
    const clean = s => (s || '').replace(/\s+/g, ' ').trim();
    const cut = s => s.length > 100 ? s.slice(0, 100) + '…' : s;
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
      if (el.localName === 'img') return clean(el.alt || el.title);
      if (el.localName === 'input' && ['button', 'submit', 'reset'].includes(el.type)) return clean(el.value);
      if (FIELD.has(role)) return clean(el.placeholder || el.title);
      if (LEAF.has(role)) return clean(el.innerText || el.title);
      return clean(el.title);
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
        if (role === 'link') line += ' -> ' + cut(el.getAttribute('href'));
        if (FIELD.has(role)) {
          const v = clean(el.isContentEditable ? el.innerText : el.localName === 'select' ? (el.selectedOptions[0] || {}).text : el.value);
          if (v) line += ': ' + JSON.stringify(cut(v));
        }
        out.push(line);
        if (!LEAF.has(role)) walk(kids(el), depth + 1);
      }
    };
    walk(document.body ? [document.body] : [], 0);
    return '- page ' + JSON.stringify(document.title) + ' ' + location.href + '\n' + out.join('\n')
      + (out.length >= MAX ? '\n… cut at ' + MAX + ' lines' : '');
    """#

    /// `el`: the element of `ref` from the last snapshot, scrolled into view.
    static let findJS = #"""
    const el = window.__kelpRefs && window.__kelpRefs.get(ref);
    if (!el || !el.isConnected) throw new Error('No ' + ref + ' on the page now: take a new snapshot');
    el.scrollIntoView({block: 'center', inline: 'center'});
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

    /// Replaces the field's text the way typing does: through the value's own setter (frameworks that wrap it, as React
    /// does, see the change), then `input` and `change`. A select takes an option's text or value. `submit` presses Enter.
    static let typeJS = #"""
    el.focus();
    if (el.isContentEditable) { document.execCommand('selectAll'); document.execCommand('insertText', false, text); }
    else {
      let v = text;
      if (el.localName === 'select') { const o = [...el.options].find(o => o.value === text || o.text.trim() === text); if (o) v = o.value; }
      const proto = el.localName === 'textarea' ? HTMLTextAreaElement.prototype
        : el.localName === 'select' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);
      el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true}));
    }
    if (submit) {
      const k = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true};
      const go = el.dispatchEvent(new KeyboardEvent('keydown', k));
      el.dispatchEvent(new KeyboardEvent('keypress', k)); el.dispatchEvent(new KeyboardEvent('keyup', k));
      if (go && el.form && el.localName !== 'textarea') el.form.requestSubmit();
    }
    """#

    static let waitJS = #"""
    return (!selector || !!document.querySelector(selector)) && (!text || !!(document.body && document.body.innerText.includes(text)));
    """#
}
