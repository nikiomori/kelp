import AppKit
import WebKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// One web page as a tab: address bar, back/forward, and Design Mode (click an element → its HTML, computed
/// styles and a cropped screenshot go into the focused agent's prompt).
@MainActor @Observable
final class BrowserTab: NSObject, TabContent, WKNavigationDelegate, WKScriptMessageHandler, NSTextFieldDelegate {
    let view: NSView
    let web: WKWebView
    private let address = NSTextField()
    private let designButton = PointerButton(frame: .zero)
    /// Shown instead of a blank page: the workspace's servers.
    private let ports: PortsView
    let app: AppModel
    private var designOn = false
    @ObservationIgnored private var clicks = DesignClicks()
    @ObservationIgnored private var clickWatch: Any?
    /// `preview:/path/page.html`: a local page shown as the browser sees it, reloaded whenever a file next to it changes.
    private var previewFile: String? { start.hasPrefix("preview:") ? String(start.dropFirst("preview:".count)) : nil }
    private var watcher: FileWatcher?
    /// The page's address and title as of its last commit or load: what the tab shows follows these.
    private var page: (url: URL?, title: String?) = (nil, nil)
    var uri: String {
        let shown = previewFile != nil ? start : page.url?.absoluteString ?? start
        return agent ? TabURI.agentPage(shown) : shown
    }
    private let start: String
    /// An agent's page (`kelp browser open`): cookies and storage of its own, gone when the tab is.
    let agent: Bool
    /// Why the last load failed, until the next one commits (`kelp browser` says it).
    var loadError: String?
    /// `kelp browser console | network` (BrowserLogs.swift): kept once an agent drives the page.
    @ObservationIgnored var watching = false
    @ObservationIgnored var logs: [String] = []
    @ObservationIgnored var requests: [String] = []
    /// `kelp browser dialog`: how the agent answers the page's next question (BrowserDialogs.swift).
    @ObservationIgnored var dialogAnswer: (accept: Bool, text: String?)?
    /// The questions the agent's page answered since the last action's answer said them.
    @ObservationIgnored var dialogs: [String] = []
    /// Downloads under way (BrowserDownloads.swift): where each goes, where from, from which page.
    @ObservationIgnored var downloading: [ObjectIdentifier: (to: URL, source: URL?, page: URL?)] = [:]
    /// What the agent's page downloaded since the last action's answer said it.
    @ObservationIgnored var downloads: [String] = []
    /// The user took the agent's page over: its questions go to the user, and the agent's commands are refused.
    var takenOver = false
    /// Under the toolbar once an agent drives the page: that it does, and Take Over / Hand Back. No height until then.
    @ObservationIgnored private let agentSlot = NSView()
    @ObservationIgnored private lazy var agentSlotHeight = agentSlot.heightAnchor.constraint(equalToConstant: 0)
    @ObservationIgnored private let agentLabel = NSTextField(labelWithString: "")
    @ObservationIgnored private let agentButton = PointerButton()
    var title: String {
        previewFile.map { ($0 as NSString).lastPathComponent } ?? page.title.flatMap { $0.isEmpty ? nil : $0 } ?? page.url?.host
            ?? String(localized: "New Page")
    }
    var icon: NSImage? { .symbol(previewFile == nil ? "safari" : "eye") }
    var toolTip: String? {
        page.url.map { agent ? String(localized: "\($0.absoluteString)\nAn agent's page: cookies and storage of its own") : $0.absoluteString }
    }

    init(uri: String, app: AppModel) {
        agent = TabURI.scheme(uri) == TabURI.agentScheme
        start = TabURI.pageURL(uri)
        self.app = app
        ports = PortsView(app: app)
        let cfg = WKWebViewConfiguration()
        if agent { cfg.websiteDataStore = .nonPersistent() }
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")   // "Inspect Element" in the page's context menu
        web = WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = true; web.isInspectable = true
        func b(_ sym: String, _ tip: String) -> NSButton { IconButton(.symbol(sym), tip: tip, target: nil, action: nil) }
        let back = b("chevron.left", String(localized: "Back")), fwd = b("chevron.right", String(localized: "Forward"))
        let reload = b("arrow.clockwise", String(localized: "Reload (⌘R)")), ext = b("safari", String(localized: "Open in Safari"))
        let more = b("ellipsis.circle", String(localized: "More"))
        address.placeholderString = String(localized: "Search or enter address")
        address.lineBreakMode = .byTruncatingTail
        address.bezelStyle = .roundedBezel
        designButton.setButtonType(.pushOnPushOff)
        designButton.imagePosition = .imageOnly
        designButton.symbolConfiguration = .init(pointSize: Metrics.iconPoint, weight: Metrics.iconWeight)
        designButton.contentTintColor = .secondaryLabelColor
        designButton.image = .symbol("cursorarrow.rays", String(localized: "Design Mode"))
        designButton.toolTip = String(localized: "Design Mode: click an element to send its source, HTML, CSS and a screenshot to the agent (⌥-click copies them)")
        let bar = Bar.content([back, fwd, reload, address], [designButton, ext, more], stretching: address)
        let body = NSView()
        for x in [web, ports] as [NSView] { body.pin(x) }
        view = stacked(bar, agentSlot, body)
        super.init()
        agentSlotHeight.isActive = true
        ports.onOpen = { [weak self] u in self?.load(u) }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.configuration.userContentController.add(WeakHandler(self), name: "kelp")
        address.delegate = self
        address.target = self
        address.action = #selector(go)
        back.target = web; back.action = #selector(WKWebView.goBack(_:))
        fwd.target = web; fwd.action = #selector(WKWebView.goForward(_:))
        reload.target = web; reload.action = #selector(WKWebView.reload(_:))
        ext.target = self; ext.action = #selector(openExternal)
        more.target = self; more.action = #selector(showMore(_:))
        designButton.target = self; designButton.action = #selector(toggleDesign)
        if agent { watch() }
        load(start)
    }

    /// Shows the agent's strip (an agent drove the page) in its current state.
    func showAgentBar() {
        if agentSlot.subviews.isEmpty {
            let icon = NSImageView(image: .symbol("cursorarrow.motionlines") ?? NSImage())
            icon.contentTintColor = .themeAccent
            agentLabel.font = .ui(12)
            agentLabel.textColor = .secondaryLabelColor
            agentLabel.lineBreakMode = .byTruncatingTail
            agentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            agentButton.padding = Metrics.gap
            agentButton.restFill = .fillRest
            agentButton.onClick = { [weak self] in self?.toggleTakeOver() }
            agentSlot.pin(Bar.content([icon, agentLabel], [agentButton]))
            agentSlotHeight.isActive = false
        }
        agentLabel.stringValue = takenOver ? String(localized: "You took this page over: the agent can only look at it")
            : String(localized: "An agent is using this page")
        agentButton.title = takenOver ? String(localized: "Hand Back") : String(localized: "Take Over")
        agentButton.toolTip = takenOver ? String(localized: "Let the agent click and type here again")
            : String(localized: "Stop the agent's clicks and typing here; the page's questions come to you")
    }

    private func toggleTakeOver() { takenOver.toggle(); showAgentBar() }

    func focus() { if web.url == nil { view.window?.makeFirstResponder(address) } else { view.window?.makeFirstResponder(web) } }

    func load(_ raw: String) {
        if let f = previewFile, raw == start {
            let u = URL(fileURLWithPath: f), dir = u.deletingLastPathComponent()
            web.loadFileURL(u, allowingReadAccessTo: dir); address.stringValue = u.absoluteString
            watcher = FileWatcher(root: dir.path) { [weak self] _ in MainActor.assumeIsolated { _ = self?.web.reload() } }   // delivered on main
            return
        }
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s != "https:", !s.hasPrefix("about:blank") else { ports.isHidden = false; return }
        let text = s.contains("://") ? s : (s.hasPrefix("localhost") || s.first?.isNumber == true ? "http://" + s
            : s.contains(".") && !s.contains(" ") ? "https://" + s
            : "https://duckduckgo.com/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s))
        guard let url = URL(string: text) else { NSSound.beep(); return }
        web.load(URLRequest(url: url)); address.stringValue = url.absoluteString
    }

    @objc private func go() { load(address.stringValue); view.window?.makeFirstResponder(web) }
    @objc private func openExternal() { if let u = web.url { NSWorkspace.shared.open(u) } }

    @objc private func showMore(_ sender: NSButton) {
        let m = NSMenu()
        m.add(String(localized: "Reload Ignoring Cache")) { [weak self] in self?.web.reloadFromOrigin() }
        m.add(String(localized: "Copy Screenshot")) { [weak self] in
            self?.web.takeSnapshot(with: nil) { img, _ in   // WebKit answers on main
                MainActor.assumeIsolated {
                    guard let img else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                    Banner.show(String(localized: "Screenshot copied"))
                }
            }
        }
        m.addItem(.separator())
        m.add(String(localized: "Clear Cookies and Data for This Site")) { [weak self] in self?.clearSiteData() }
        m.addItem(.separator())
        let tip = m.addItem(withTitle: String(localized: "Inspect: right-click the page › Inspect Element"), action: nil, keyEquivalent: "")
        tip.isEnabled = false
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func clearSiteData() {
        guard let host = web.url?.host else { NSSound.beep(); return }
        let store = web.configuration.websiteDataStore, types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { [weak self] records in
            guard self != nil else { return }
            let mine = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            store.removeData(ofTypes: types, for: mine) { [weak self] in   // WebKit answers on main
                MainActor.assumeIsolated {
                    Banner.show(String(localized: "Cleared \(host)'s cookies and data")); self?.web.reload()
                }
            }
        }
    }

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        if w.url?.absoluteString != "about:blank" { loadError = nil }   // the error page (about:blank) keeps it
        address.stringValue = w.url?.absoluteString ?? ""
        ports.isHidden = true
        page = (w.url, w.title)
        if watching, let u = w.url?.absoluteString, u != "about:blank" { noteLog("[page] \(u)") }
    }
    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if watching, r.isForMainFrame, let h = r.response as? HTTPURLResponse, let u = h.url {
            noteRequest("\(h.statusCode) \(u.absoluteString) (page)")
        }
        return Self.downloads(r) ? .download : .allow
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        address.stringValue = w.url?.absoluteString ?? ""; page = (w.url, w.title)
        if designOn { w.evaluateJavaScript(Self.designJS(accent: .themeAccent)) }
        if watching { w.evaluateJavaScript(Self.watchJS) }   // a load begun before watch(): from now
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { showError(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { showError(e) }
    private func showError(_ e: Error) {
        let ns = e as NSError
        // Not failures: a navigation cancelled by the next one (a click or Back while loading), a download handed off.
        // Showing the error page for those cancelled the navigation the user had just started.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled || ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        loadError = ns.localizedDescription + ((ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).map { " (\($0))" } ?? "")
        let text = ns.localizedDescription + " " + String(localized: "Is the dev server running?")
        web.loadHTMLString(EmptyStateView.html(String(localized: "Can't open this page"), text: text), baseURL: nil)
    }

    // MARK: Design Mode
    /// The click watch goes with the tab (a closed tab in Design Mode would leave it on every click).
    func close() async -> Bool {
        if let w = clickWatch { NSEvent.removeMonitor(w); clickWatch = nil }
        return true
    }

    @objc func toggleDesign() {
        designOn.toggle(); designButton.state = designOn ? .on : .off
        designButton.restFill = designOn ? .fillSelected : nil   // on, it stays pressed in, as a toggle in a bar does
        designButton.contentTintColor = designOn ? .themeAccent : .secondaryLabelColor
        // The user's own clicks on the page, as AppKit sees them: a page can post without one, it can't make one.
        if designOn, clickWatch == nil {
            clickWatch = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
                if let self, e.window === web.window, web.bounds.contains(web.convert(e.locationInWindow, from: nil)) { clicks.note() }
                return e
            }
        } else if !designOn, let w = clickWatch { NSEvent.removeMonitor(w); clickWatch = nil }
        designButton.contentTintColor = designOn ? .themeAccent : .secondaryLabelColor
        web.evaluateJavaScript(designOn ? Self.designJS(accent: .themeAccent) : "window.__kelpOff && window.__kelpOff()")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "kelpWatch" { note(m); return }
        // Any site can post to this handler: only one message per click the user made while Design Mode is on counts.
        guard designOn, m.frameInfo.isMainFrame, clicks.take(), let d = m.body as? [String: Any] else { return }
        let r = d["rect"] as? [String: Double] ?? [:]
        let rect = CGRect(x: r["x"] ?? 0, y: r["y"] ?? 0, width: max(1, r["w"] ?? 1), height: max(1, r["h"] ?? 1)).insetBy(dx: -8, dy: -8)
        let cfg = WKSnapshotConfiguration(); cfg.rect = rect.intersection(web.bounds)
        web.takeSnapshot(with: cfg) { [weak self] img, _ in MainActor.assumeIsolated { self?.sendDesign(d, image: img) } }   // on main
    }

    /// The image as a PNG at `path` (a temporary file named after `kind` when nil); nil when it couldn't be written.
    static func savePNG(_ image: NSImage?, kind: String, to path: String? = nil) -> String? {
        guard let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let u = path.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("kelp-\(kind)-\(UUID().uuidString.prefix(6)).png")
        do { try png.write(to: u) } catch { return nil }
        return u.path
    }

    /// A field the page wrote, for the draft: one line, short, with nothing that ends Kelp's framing (a fence, a backtick).
    nonisolated static func pageText(_ v: Any?, most: Int = 200) -> String {
        String((v as? String ?? "").filter { !$0.isNewline && $0 != "`" }.prefix(most))
    }

    /// The element's markup as the page gave it, in a fence it can't close.
    nonisolated static func pageMarkup(_ v: Any?) -> String {
        String((v as? String ?? "").prefix(4000)).replacingOccurrences(of: "```", with: "`\u{200B}``")
    }

    private func sendDesign(_ d: [String: Any], image: NSImage?) {
        let shot = Self.savePNG(image, kind: "design") ?? ""
        let styles = (d["styles"] as? [String: String] ?? [:]).filter { !$0.value.isEmpty && $0.value != "none" && $0.value != "normal" }
            .sorted { $0.key < $1.key }.prefix(80).map { "  \(Self.pageText($0.key, most: 60)): \(Self.pageText($0.value));" }.joined(separator: "\n")
        let source = relativeSource(Self.pageText(d["source"])), component = Self.pageText(d["component"])
        // The address is Kelp's own reading, not the page's word.
        let msg = """
        Design change for the element `\(Self.pageText(d["selector"]))` on \(web.url?.absoluteString ?? ""):
        \(source.isEmpty ? "" : "Source: \(source)\(component.isEmpty ? "" : " (component \(component))")\n")
        ```html
        \(Self.pageMarkup(d["html"]))
        ```
        Computed styles:
        ```css
        \(styles)
        ```
        \(shot.isEmpty ? "" : "Screenshot: \(shot)\n")
        Change:\u{20}
        """
        if d["alt"] as? Bool == true {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(msg, forType: .string)
            Banner.show(source.isEmpty ? String(localized: "Element details copied") : String(localized: "Copied \(source) and the element's details")); return
        }
        guard let sid = app.workbench.focusedSession else {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(msg, forType: .string)
            Banner.show(String(localized: "No agent on this screen — the element details were copied to the clipboard.")); return
        }
        // The page wrote most of it (html, styles, selector): a draft the user reads and sends, never Enter, and the
        // daemon types it as plain text (`typeable`: no escapes or control keys).
        Task { await app.call(SessionSend(id: sid, text: msg, enter: false)) }
        app.workbench.focus(session: sid)
    }

    /// A dev server's absolute path as the workspace sees it (`src/App.tsx:12`); others stay as they are.
    private func relativeSource(_ s: String) -> String {
        var s = s.replacingOccurrences(of: "file://", with: "")
        if let root = app.worktree(app.workbench.workspaceId)?.path {
            for r in [root, (root as NSString).resolvingSymlinksInPath] where s.hasPrefix(r + "/") { s = String(s.dropFirst(r.count + 1)) }
        }
        return s
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
    static func designJS(accent: NSColor) -> String { designScript.replacingOccurrences(of: "ACCENT", with: accent.hexString) }
    private static let designScript = sourceJS + """
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

/// The user's clicks on the page in Design Mode: each one lets one element's message through, within a second of it.
struct DesignClicks {
    private var at: Date?
    mutating func note(_ now: Date = Date()) { at = now }
    mutating func take(_ now: Date = Date()) -> Bool {
        defer { at = nil }
        return at.map { now.timeIntervalSince($0) < 1 } ?? false
    }
}
