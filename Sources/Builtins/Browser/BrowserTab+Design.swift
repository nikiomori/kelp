// A browser tab's Design Mode: clicks on the page sent to an agent with a picture and the element's source.
import AppKit
import Core
import DesignKit
import KelpKit
import WebKit
import WorkbenchKit

extension BrowserTab {
    // MARK: Design Mode
    /// The click watch goes with the tab (a closed tab in Design Mode would leave it on every click).
    func close() async -> Bool {
        if let monitor = clickWatch {
            NSEvent.removeMonitor(monitor)
            clickWatch = nil
        }
        return true
    }

    @objc func toggleDesign() {
        designOn.toggle()
        designButton.state = designOn ? .on : .off
        designButton.restFill = designOn ? .fillSelected : nil   // on, it stays pressed in, as a toggle in a bar does
        designButton.contentTintColor = designOn ? .themeAccent : .secondaryLabelColor
        // The user's own clicks on the page, as AppKit sees them: a page can post without one, it can't make one.
        if designOn, clickWatch == nil {
            clickWatch = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                if let self, event.window === web.window,
                    web.bounds.contains(web.convert(event.locationInWindow, from: nil))
                {
                    clicks.note()
                }
                return event
            }
        } else if !designOn, let monitor = clickWatch {
            NSEvent.removeMonitor(monitor)
            clickWatch = nil
        }
        designButton.contentTintColor = designOn ? .themeAccent : .secondaryLabelColor
        web.evaluateJavaScript(
            designOn ? Self.designJS(accent: .themeAccent) : "window.__kelpOff && window.__kelpOff()")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "kelpWatch" {
            note(message)
            return
        }
        // Any site can post to this handler: only one message per click the user made while Design Mode is on counts.
        guard designOn, message.frameInfo.isMainFrame, clicks.take(), let element = message.body as? [String: Any]
        else { return }
        let frame = element["rect"] as? [String: Double] ?? [:]
        let rect = CGRect(
            x: frame["x"] ?? 0, y: frame["y"] ?? 0, width: max(1, frame["w"] ?? 1), height: max(1, frame["h"] ?? 1)
        )
        .insetBy(dx: -8, dy: -8)
        let cfg = WKSnapshotConfiguration()
        cfg.rect = rect.intersection(web.bounds)
        web.takeSnapshot(with: cfg) { [weak self] img, _ in
            MainActor.assumeIsolated { self?.sendDesign(element, image: img) }
        }   // on main
    }

    /// The image as a PNG at `path` (a temporary file named after `kind` when nil); nil when it couldn't be written.
    static func savePNG(_ image: NSImage?, kind: String, to path: String? = nil) -> String? {
        guard let tiff = image?.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let url =
            path.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "kelp-\(kind)-\(UUID().uuidString.prefix(6)).png")
        do { try png.write(to: url) } catch { return nil }
        return url.path
    }

    /// A field the page wrote, for the draft: one line, short, with nothing that ends Kelp's framing (a fence, a backtick).
    nonisolated static func pageText(_ value: Any?, most: Int = 200) -> String {
        String((value as? String ?? "").filter { !$0.isNewline && $0 != "`" }.prefix(most))
    }

    /// The element's markup as the page gave it, in a fence it can't close.
    nonisolated static func pageMarkup(_ value: Any?) -> String {
        String((value as? String ?? "").prefix(4000)).replacingOccurrences(of: "```", with: "`\u{200B}``")
    }

    private func sendDesign(_ element: [String: Any], image: NSImage?) {
        let shot = Self.savePNG(image, kind: "design") ?? ""
        let styles = (element["styles"] as? [String: String] ?? [:]).filter {
            !$0.value.isEmpty && $0.value != "none" && $0.value != "normal"
        }
        .sorted { $0.key < $1.key }.prefix(80).map {
            "  \(Self.pageText($0.key, most: 60)): \(Self.pageText($0.value));"
        }.joined(separator: "\n")
        let source = relativeSource(Self.pageText(element["source"])), component = Self.pageText(element["component"])
        // The address is Kelp's own reading, not the page's word.
        let msg = """
            Design change for the element `\(Self.pageText(element["selector"]))` on \(web.url?.absoluteString ?? ""):
            \(source.isEmpty ? "" : "Source: \(source)\(component.isEmpty ? "" : " (component \(component))")\n")
            ```html
            \(Self.pageMarkup(element["html"]))
            ```
            Computed styles:
            ```css
            \(styles)
            ```
            \(shot.isEmpty ? "" : "Screenshot: \(shot)\n")
            Change:\u{20}
            """
        if element["alt"] as? Bool == true {
            copyText(msg)
            Banner.show(
                source.isEmpty
                    ? String(localized: "Element details copied")
                    : String(localized: "Copied \(source) and the element's details"))
            return
        }
        guard let sid = app.workbench.focusedSession else {
            copyText(msg)
            Banner.show(
                String(localized: "No agent on this screen — the element details were copied to the clipboard."))
            return
        }
        // The page wrote most of it (html, styles, selector): a draft the user reads and sends, never Enter, and the
        // daemon types it as plain text (`typeable`: no escapes or control keys).
        Task { await app.call(SessionSend(id: sid, text: msg, enter: false)) }
        app.workbench.focus(session: sid)
    }

    /// A dev server's absolute path as the workspace sees it (`src/App.tsx:12`); others stay as they are.
    private func relativeSource(_ source: String) -> String {
        var path = source.replacingOccurrences(of: "file://", with: "")
        if let root = app.worktree(app.workbench.workspaceId)?.path {
            for prefix in [root, (root as NSString).resolvingSymlinksInPath] where path.hasPrefix(prefix + "/") {
                path = String(path.dropFirst(prefix.count + 1))
            }
        }
        return path
    }

    /// Where the element's component is written, from what dev builds leave on DOM nodes: Svelte's `__svelte_meta`,
    /// inspector plugins' `data-insp-path` / `data-inspector-*`, React's fiber (`_debugSource`, or React 19's `_debugStack`),
    /// Vue's `__vueParentComponent.type.__file`. The nearest ancestor that has one wins.
    static let sourceJS = """
        const __kelpSource = el => {
          const strip = u => u.replace(/^https?:\\/\\/[^/]+\\//, '').replace(/\\?[^:]*/, '').replace(/^@fs\\//, '/');
          for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
            const sv = n.__svelte_meta && n.__svelte_meta.loc;
            if (sv) return {source: sv.file + ':' + sv.line};
            const ip = n.getAttribute && n.getAttribute('data-insp-path');
            if (ip) { const p = ip.split(':'); return {source: p[0] + ':' + p[1]}; }
            const rp = n.getAttribute && n.getAttribute('data-inspector-relative-path');
            if (rp) return {source: rp + ':' + (n.getAttribute('data-inspector-line') || 1)};
            const fk = Object.keys(n).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
            if (fk) {
              let component = null;
              for (let f = n[fk]; f; f = f.return) {
                if (!component && typeof f.type === 'function') component = f.type.displayName || f.type.name || null;
                if (f._debugSource) return {source: f._debugSource.fileName + ':' + f._debugSource.lineNumber, component};
                const st = f._debugStack && f._debugStack.stack;
                if (st) {
                  const line = st.split('\\n').map(l => (l.match(/at (?:(\\S+) \\()?(https?:\\/\\/\\S+?):(\\d+):\\d+\\)?$/) || []))\
        .find(m => m[2] && !/node_modules|react-dom|react\\.|jsx-dev-runtime/.test(m[2]));
                  if (line) return {source: strip(line[2]) + ':' + line[3], component: component || line[1] || null};
                }
              }
              if (component) return {component};
            }
            const vf = n.__vueParentComponent && n.__vueParentComponent.type;
            if (vf && vf.__file) return {source: vf.__file, component: vf.__name || vf.name || null};
          }
          return {};
        };
        """

    /// The overlay in the system's accent colour (the page has no other way to know it).
    static func designJS(accent: NSColor) -> String {
        designScript.replacingOccurrences(of: "ACCENT", with: accent.hexString)
    }
    private static let designScript =
        sourceJS + """
            (() => { if (window.__kelp) return; window.__kelp = true;
             const box = document.createElement('div');
             box.style.cssText = 'position:fixed;pointer-events:none;border:2px solid ACCENT;background:ACCENT1f;z-index:2147483647;border-radius:3px;display:none';
             const tag = document.createElement('div');
             tag.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;background:ACCENT;color:#fff;font:11px -apple-system;padding:2px 6px;border-radius:4px;display:none';
             document.documentElement.append(box, tag);
             const move = e => { const r = e.target.getBoundingClientRect();
               Object.assign(box.style, {left: r.left+'px', top: r.top+'px', width: r.width+'px', height: r.height+'px', display: 'block'});
               tag.textContent = e.target.tagName.toLowerCase() + (e.target.classList.length ? '.' + [...e.target.classList].slice(0,2).join('.') : '')\
             + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
               Object.assign(tag.style, {left: r.left+'px', top: Math.max(0, r.top-20)+'px', display: 'block'}); };
             const path = n => { if (!n || n.nodeType !== 1) return ''; if (n.id) return '#' + n.id;
               let s = n.tagName.toLowerCase(); if (n.classList.length) s += '.' + [...n.classList].slice(0,3).join('.');
               const p = n.parentElement; if (!p) return s; const sib = [...p.children].filter(c => c.tagName === n.tagName);
               if (sib.length > 1) s += ':nth-of-type(' + (sib.indexOf(n)+1) + ')'; return path(p) + ' > ' + s; };
             const click = e => { e.preventDefault(); e.stopPropagation(); const el = e.target, r = el.getBoundingClientRect(), cs = getComputedStyle(el);
               const keys = ['display','position','width','height','margin','padding','color','background-color','font-family','font-size','font-weight',\
            'line-height','border','border-radius','gap','flex-direction','justify-content','align-items','grid-template-columns','box-shadow','opacity'];
               const styles = {}; keys.forEach(k => styles[k] = cs.getPropertyValue(k));
               const src = __kelpSource(el);
               window.webkit.messageHandlers.kelp.postMessage({selector: path(el), html: el.outerHTML.slice(0, 4000), styles,
                 rect: {x: r.left, y: r.top, w: r.width, h: r.height},
                 url: location.href, source: src.source || null, component: src.component || null, alt: e.altKey}); };
             document.addEventListener('mousemove', move, true); document.addEventListener('click', click, true);
             window.__kelpOff = () => { document.removeEventListener('mousemove', move, true); document.removeEventListener('click', click, true);
               box.remove(); tag.remove(); window.__kelp = false; };
            })();
            """
}
