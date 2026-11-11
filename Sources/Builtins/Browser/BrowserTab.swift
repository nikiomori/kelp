import AppKit
import Core
import DesignKit
import KelpKit
import WebKit
import WorkbenchKit

/// One web page as a tab: address bar, back/forward, and Design Mode (click an element → its HTML, computed
/// styles and a cropped screenshot go into the focused agent's prompt).
@MainActor @Observable
final class BrowserTab: NSObject, TabContent, WKNavigationDelegate, WKScriptMessageHandler, NSTextFieldDelegate {
    let view: NSView
    let web: WKWebView
    private let address = NSTextField()
    let designButton = PointerButton(frame: .zero)
    /// Shown instead of a blank page: the workspace's servers.
    private let ports: PortsView
    let app: AppModel
    var designOn = false
    @ObservationIgnored var clicks = DesignClicks()
    @ObservationIgnored var clickWatch: Any?
    /// `preview:/path/page.html`: a local page shown as the browser sees it, reloaded whenever a file next to it changes.
    private var previewFile: String? { start.hasPrefix("preview:") ? String(start.dropFirst("preview:".count)) : nil }
    private var watcher: FileWatcher?
    /// The page's address and title as of its last commit or load: what the tab shows follows these.
    private var page: (url: URL?, title: String?) = (nil, nil)
    var uri: String {
        let shown = previewFile != nil ? start : page.url?.absoluteString ?? start
        return agent ? TabURI.agentPage(shown) : shown
    }
    let start: String
    /// An agent's page (`kelp browser open`): cookies and storage of its own, gone when the tab is.
    let agent: Bool
    /// Why the last load failed, until the next one commits (`kelp browser` says it).
    var loadError: String?
    /// The address that failed while its error page shows: the bar, the tab and Reload keep to it, not to about:blank.
    private var failed: URL?
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []
    /// ⌘F's card (BrowserFind.swift), made the first time.
    @ObservationIgnored var finding: FindCard?
    /// The workspace's servers while a local address failed: the page loads again once its port is served.
    @ObservationIgnored private lazy var serving = Watched(.ports, in: app)
    /// How far the page has loaded, as a line under the bar while it loads.
    @ObservationIgnored private let progress = NSView()
    @ObservationIgnored private lazy var progressWidth = progress.widthAnchor.constraint(equalToConstant: 0)
    /// The page's size, set by the user (⋯ › Page Size) or the agent (`kelp browser viewport`): the page sits at the
    /// pane's top, in the middle, at that size; nil fills the pane (`placeWeb`).
    @ObservationIgnored var viewport: CGSize?
    /// The user's typing in the address bar removed text: no completion is offered for it.
    @ObservationIgnored private var deleting = false
    private let back = IconButton(.symbol("chevron.left"), tip: String(localized: "Back"), target: nil, action: nil)
    private let forward = IconButton(
        .symbol("chevron.right"), tip: String(localized: "Forward"), target: nil, action: nil)
    private let reload = IconButton(
        .symbol("arrow.clockwise"), tip: String(localized: "Reload (⌘R)"), target: nil, action: nil)
    /// What `kelp browser` keeps here once an agent drives the page (`watch()`); nil on a page only the user browses.
    @ObservationIgnored var drive: AgentDrive?
    /// Downloads under way (BrowserDownloads.swift): where each goes, where from, from which page.
    @ObservationIgnored var downloading: [ObjectIdentifier: (to: URL, source: URL?, page: URL?)] = [:]
    /// When WebKit last decided a navigation is a download that has no destination yet: an action's answer waits for it
    /// (5 s at most, in case it never starts), since on a busy Mac it can begin after the answer's first look.
    @ObservationIgnored var downloadDecided: Date?
    var downloadComing: Bool { downloadDecided.map { Date().timeIntervalSince($0) < 5 } ?? false }
    /// Under the toolbar once an agent drives the page: that it does, and Take Over / Hand Back. No height until then.
    @ObservationIgnored private let agentSlot = NSView()
    @ObservationIgnored private lazy var agentSlotHeight = agentSlot.heightAnchor.constraint(equalToConstant: 0)
    @ObservationIgnored private let agentLabel = NSTextField(labelWithString: "")
    @ObservationIgnored private let agentButton = PointerButton()
    @ObservationIgnored private var webFill: [NSLayoutConstraint] = []
    @ObservationIgnored private var webFixed: [NSLayoutConstraint] = []
    var title: String {
        previewFile.map { ($0 as NSString).lastPathComponent } ?? page.title.flatMap { $0.isEmpty ? nil : $0 } ?? page
            .url?.host
            ?? String(localized: "New Page")
    }
    var icon: NSImage? { .symbol(previewFile == nil ? "safari" : "eye") }
    var toolTip: String? {
        page.url.map {
            agent
                ? String(localized: "\($0.absoluteString)\nAn agent's page: cookies and storage of its own")
                : $0.absoluteString
        }
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
        // A window the user's page opened (BrowserDialogs.swift): WebKit made it, with the opener's cookies and a
        // `window.opener`, and is loading it already.
        let opened = BrowserTab.opened.removeValue(forKey: start)
        web = opened ?? WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        func b(_ sym: String, _ tip: String) -> NSButton {
            IconButton(.symbol(sym), tip: tip, target: nil, action: nil)
        }
        let browser = Self.defaultBrowser()
        let ext = IconButton(browser?.icon ?? .symbol("safari"), tip: Self.openIn(browser), target: nil, action: nil)
        let more = b("ellipsis.circle", String(localized: "More"))
        address.placeholderString = String(localized: "Search or enter address")
        address.lineBreakMode = .byTruncatingTail
        address.bezelStyle = .roundedBezel
        designButton.setButtonType(.pushOnPushOff)
        designButton.imagePosition = .imageOnly
        designButton.symbolConfiguration = .chrome()
        designButton.contentTintColor = .secondaryLabelColor
        designButton.image = .symbol("cursorarrow.rays", String(localized: "Design Mode"))
        designButton.toolTip = String(
            localized:
                "Design Mode: click an element to send its source, HTML, CSS and a screenshot to the agent (⌥-click copies them)"
        )
        let bar = Bar.content([back, forward, reload, address], [designButton, ext, more], stretching: address)
        let body = NSView()
        web.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(web)
        body.pin(ports)
        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.themeAccent.cgColor
        progress.alphaValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(progress)
        let box = BrowserBox()
        box.pin(stacked(bar, agentSlot, body))
        view = box
        super.init()
        box.reload = { [weak self] in self?.reloadPage() }
        box.find = { [weak self] in self?.find($0) }
        agentSlotHeight.isActive = true
        webFill = [
            web.topAnchor.constraint(equalTo: body.topAnchor), web.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: body.trailingAnchor)
        ]
        // Wider than the pane: from its left edge, cut on the right; taller: cut at the bottom.
        let middle = web.centerXAnchor.constraint(equalTo: body.centerXAnchor)
        middle.priority = .defaultLow
        webFixed = [
            web.topAnchor.constraint(equalTo: body.topAnchor),
            web.leadingAnchor.constraint(greaterThanOrEqualTo: body.leadingAnchor), middle
        ]
        NSLayoutConstraint.activate(webFill)
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: body.topAnchor),
            progress.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2), progressWidth
        ])
        ports.onOpen = { [weak self] u in self?.load(u) }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.configuration.userContentController.add(WeakHandler(self), name: "kelp")
        address.delegate = self
        address.target = self
        address.action = #selector(go)
        back.target = web
        back.action = #selector(WKWebView.goBack(_:))
        forward.target = web
        forward.action = #selector(WKWebView.goForward(_:))
        reload.target = self
        reload.action = #selector(reloadOrStop)
        follow()
        ext.target = self
        ext.action = #selector(openExternal)
        more.target = self
        more.action = #selector(showMore(_:))
        designButton.target = self
        designButton.action = #selector(toggleDesign)
        if agent { watch() }
        track(owner: self) { [weak self] in
            self?.failedServed ?? false
        } changed: { [weak self] served in
            if served { self?.reloadPage() }
        }
        if opened == nil {
            load(start)
        } else {
            ports.isHidden = true
            showPage()
        }
    }

    /// The local address that failed is served now (its dev server started in this screen).
    private var failedServed: Bool {
        guard let failed, let port = failed.port, Self.isLocal(failed), let wid = serving.key else { return false }
        // A remote project's port is served here once forwarded (`here`).
        return app.latest(PortsEvent.self, wid)?.ports.contains { ($0.host == nil ? $0.port : $0.here) == port } == true
    }

    static func isLocal(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
            || url.host?.hasSuffix(".localhost") == true
    }

    /// Shows the agent's strip (an agent drove the page) in its current state.
    func showAgentBar() {
        if agentSlot.subviews.isEmpty {
            let icon = NSImageView(image: .symbol("cursorarrow.motionlines"))
            icon.contentTintColor = .themeAccent
            agentLabel.font = .ui(TextSize.row)
            agentLabel.textColor = .secondaryLabelColor
            agentLabel.lineBreakMode = .byTruncatingTail
            agentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            agentButton.padding = Metrics.gap
            agentButton.restFill = .fillRest
            agentButton.onClick = { [weak self] in self?.toggleTakeOver() }
            agentSlot.pin(Bar.content([icon, agentLabel], [agentButton]))
            agentSlotHeight.isActive = false
        }
        let takenOver = drive?.takenOver == true
        agentLabel.stringValue =
            (takenOver
                ? String(localized: "You took this page over: the agent waits until you hand it back")
                : String(localized: "An agent is using this page"))
            + (viewport.map { " · " + String(localized: "page \(Int($0.width))×\(Int($0.height))") } ?? "")
        agentButton.title = takenOver ? String(localized: "Hand Back") : String(localized: "Take Over")
        agentButton.toolTip =
            takenOver
            ? String(localized: "Let the agent click and type here again")
            : String(localized: "Stop the agent's clicks and typing here; the page's questions come to you")
    }

    private func toggleTakeOver() {
        drive?.takenOver.toggle()
        showAgentBar()
    }

    /// The page at the size the agent set (`AgentDrive.viewport`), or filling the pane.
    func placeWeb() {
        NSLayoutConstraint.deactivate(webFill + webFixed)
        webFixed.removeSubrange(3...)
        if let viewport {
            webFixed += [
                web.widthAnchor.constraint(equalToConstant: viewport.width),
                web.heightAnchor.constraint(equalToConstant: viewport.height)
            ]
            NSLayoutConstraint.activate(webFixed)
        } else {
            NSLayoutConstraint.activate(webFill)
        }
        if !agentSlot.subviews.isEmpty { showAgentBar() }
    }

    /// The bar follows the page as WebKit changes it (KVO, delivered on the main thread): Back and Forward only when
    /// there's a page that way, Reload turns into Stop while loading, and a single-page app's own address and title
    /// changes (pushState, document.title) reach the bar and the tab, not just loads.
    private func follow() {
        watches = [
            web.observe(\.canGoBack, options: .initial) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.showButtons() }
            },
            web.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.showButtons() } },
            web.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.showButtons() } },
            web.observe(\.estimatedProgress) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.showProgress() }
            },
            web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.showPage() } },
            web.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.showPage() } }
        ]
    }

    private func showButtons() {
        back.isEnabled = web.canGoBack
        forward.isEnabled = web.canGoForward
        reload.image = .symbol(web.isLoading ? "xmark" : "arrow.clockwise")
        reload.toolTip = web.isLoading ? String(localized: "Stop Loading") : String(localized: "Reload (⌘R)")
        showProgress()
    }

    /// The line grows as the page loads and fades once it has.
    private func showProgress() {
        let width = progress.superview?.bounds.width ?? 0, loading = web.isLoading
        if loading, progress.alphaValue == 0 { progressWidth.constant = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = loading ? Motion.fast : Motion.disappear
            progressWidth.animator().constant = width * (loading ? web.estimatedProgress : 1)
            progress.animator().alphaValue = loading && web.estimatedProgress < 1 ? 1 : 0
        }
    }

    /// The page's address and title in the bar and the tab; the bar keeps what the user is typing in it.
    private func showPage() {
        let blank = web.url?.absoluteString == "about:blank"
        guard let url = blank ? failed ?? web.url : web.url else { return }
        page = (url, blank ? nil : web.title)
        if address.currentEditor() == nil, previewFile == nil { address.stringValue = url.absoluteString }
    }

    @objc private func reloadOrStop() {
        if web.isLoading { web.stopLoading() } else { reloadPage() }
    }

    /// Reload, or on the error page another try at the address that failed (a dev server that has started since).
    func reloadPage(fromOrigin: Bool = false) {
        if let failed {
            web.load(URLRequest(url: failed))
        } else if fromOrigin {
            web.reloadFromOrigin()
        } else {
            web.reload()
        }
    }

    /// Completes the address as it's typed from the pages visited (`BrowserHistory`), the rest selected, as Safari does.
    func controlTextDidChange(_ notification: Notification) {
        guard let editor = address.currentEditor() as? NSTextView, !deleting else { return }
        let typed = address.stringValue, end = (typed as NSString).length
        guard editor.selectedRange == NSRange(location: end, length: 0), let rest = BrowserHistory.completion(typed)
        else { return }
        address.stringValue = typed + rest
        editor.selectedRange = NSRange(location: end, length: (rest as NSString).length)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        deleting = [
            #selector(NSText.delete(_:)), #selector(NSTextView.deleteBackward(_:)),
            #selector(NSTextView.deleteForward(_:)), #selector(NSTextView.deleteWordBackward(_:))
        ].contains(selector)
        return false
    }

    func focus() {
        if web.url == nil { view.window?.makeFirstResponder(address) } else { view.window?.makeFirstResponder(web) }
    }

    func load(_ raw: String) {
        if let previewFile, raw == start {
            let fileURL = URL(fileURLWithPath: previewFile), dir = fileURL.deletingLastPathComponent()
            web.loadFileURL(fileURL, allowingReadAccessTo: dir)
            address.stringValue = fileURL.absoluteString
            watcher = FileWatcher(root: dir.path) { [weak self] _ in MainActor.assumeIsolated { _ = self?.web.reload() }
            }   // delivered on main
            return
        }
        let typed = raw.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, typed != "https:", !typed.hasPrefix("about:blank") else {
            ports.isHidden = false
            return
        }
        let text =
            typed.contains("://")
            ? typed
            : (typed.hasPrefix("localhost") || typed.first?.isNumber == true
                ? "http://" + typed
                : typed.contains(".") && !typed.contains(" ")
                    ? "https://" + typed
                    : "https://duckduckgo.com/?q="
                        + (typed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? typed))
        guard let url = URL(string: text) else {
            NSSound.beep()
            return
        }
        web.load(URLRequest(url: url))
        address.stringValue = url.absoluteString
    }

    @objc private func go() {
        load(BrowserHistory.address(for: address.stringValue))
        view.window?.makeFirstResponder(web)
    }
    @objc private func openExternal() { if let url = web.url { PreviewLinks.openOutside(url) } }

    private static func openIn(_ browser: (name: String, icon: NSImage)?) -> String {
        browser.map { String(localized: "Open in \($0.name)") } ?? String(localized: "Open in Browser")
    }

    /// The browser that opens web links on this Mac, by name and with its icon: the button says where the page goes.
    private static func defaultBrowser() -> (name: String, icon: NSImage)? {
        guard let probe = URL(string: "https://example.com"),
            let app = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: Metrics.appIcon, height: Metrics.appIcon)
        return ((FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension, icon)
    }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        menu.add(Self.openIn(Self.defaultBrowser())) { [weak self] in self?.openExternal() }
        menu.addItem(pageSizes())
        menu.addItem(.separator())
        menu.add(String(localized: "Reload Ignoring Cache")) { [weak self] in self?.reloadPage(fromOrigin: true) }
        menu.add(String(localized: "Copy Screenshot")) { [weak self] in
            self?.web.takeSnapshot(with: nil) { img, _ in   // WebKit answers on main
                MainActor.assumeIsolated {
                    guard let img else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                    Banner.show(String(localized: "Screenshot copied"))
                }
            }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Clear Cookies and Data for This Site")) { [weak self] in self?.clearSiteData() }
        menu.addItem(.separator())
        let tip = menu.addItem(
            withTitle: String(localized: "Inspect: right-click the page › Inspect Element"), action: nil,
            keyEquivalent: "")
        tip.isEnabled = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// ⋯ › Page Size: the page at a phone's, a tablet's or a laptop's size, to see its layout there, or filling the pane.
    private func pageSizes() -> NSMenuItem {
        let sizes: [(String, CGSize?)] = [
            (String(localized: "Fill the Pane"), nil),
            (String(localized: "Phone 390×844"), CGSize(width: 390, height: 844)),
            (String(localized: "Tablet 820×1180"), CGSize(width: 820, height: 1180)),
            (String(localized: "Laptop 1280×800"), CGSize(width: 1280, height: 800))
        ]
        let menu = NSMenu()
        for (name, size) in sizes {
            menu.add(name) { [weak self] in
                self?.viewport = size
                self?.placeWeb()
            }
            .state = viewport == size ? .on : .off
        }
        if let viewport, !sizes.contains(where: { $0.1 == viewport }) {
            menu.add(String(localized: "\(Int(viewport.width))×\(Int(viewport.height)) (the agent's)")) {}.state = .on
        }
        let item = NSMenuItem(title: String(localized: "Page Size"), action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func clearSiteData() {
        guard let host = web.url?.host else {
            NSSound.beep()
            return
        }
        let store = web.configuration.websiteDataStore, types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { [weak self] records in
            guard self != nil else { return }
            let mine = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            store.removeData(ofTypes: types, for: mine) { [weak self] in   // WebKit answers on main
                MainActor.assumeIsolated {
                    Banner.show(String(localized: "Cleared \(host)'s cookies and data"))
                    self?.web.reload()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.absoluteString != "about:blank" {   // the error page (about:blank) keeps them
            loadError = nil
            failed = nil
            serving.key = nil
        }
        ports.isHidden = true
        showPage()
        if drive != nil, let pageURL = webView.url?.absoluteString, pageURL != "about:blank" {
            noteLog("[page] \(pageURL)")
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy
    {
        if drive != nil, navigationResponse.isForMainFrame,
            let httpResponse = navigationResponse.response as? HTTPURLResponse, let url = httpResponse.url
        {
            noteRequest("\(httpResponse.statusCode) \(url.absoluteString) (page)")
        }
        return Self.downloads(navigationResponse) ? .download : .allow
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        showPage()
        if !agent, let url = webView.url { BrowserHistory.visited(url) }
        if designOn { webView.evaluateJavaScript(Self.designJS(accent: .themeAccent)) }
        if drive != nil { webView.evaluateJavaScript(Self.watchJS) }   // a load begun before watch(): from now
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }
    /// WebKit's page process quit (a crash, memory pressure): the pane stays white until something loads again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if drive != nil { noteLog("[page] the page's process ended; loaded again") }
        reloadPage()
    }
    private func showError(_ error: Error) {
        let ns = error as NSError
        // Not failures: a navigation cancelled by the next one (a click or Back while loading), a download handed off.
        // Showing the error page for those cancelled the navigation the user had just started.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
            || ns.domain == "WebKitErrorDomain" && ns.code == 102
        {
            return
        }
        failed = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? failed
        if let failed, Self.isLocal(failed) { serving.key = app.workbench.workspaceId }
        loadError =
            ns.localizedDescription
            + ((ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).map { " (\($0))" } ?? "")
        let said = ns.localizedDescription, stop = said.hasSuffix(".") ? " " : ". "
        let local = failed.map(Self.isLocal) == true
        let text =
            said + stop
            + (local
                ? String(localized: "Is the dev server running? The page opens once it starts here; ⌘R tries now.")
                : String(localized: "Reload (⌘R) tries again."))
        web.loadHTMLString(EmptyStateView.html(String(localized: "Can't open this page"), text: text), baseURL: nil)
    }

}

/// Holds a browser tab. While the focus is in it (the page or its address), ⌘R reloads the page before the menu bar
/// gives it to Run, as in Safari; elsewhere ⌘R stays Run. ⌘F there finds on the page.
private final class BrowserBox: NSView {
    var reload: () -> Void = {}
    var find: (NSFindPanelAction?) -> Void = { _ in }

    /// Edit › Find and ⌘G from the page (WKWebView doesn't answer them): the tab's find card.
    @objc func performFindPanelAction(_ sender: Any?) {
        find(NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)))
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command, let focus = window?.firstResponder as? NSView, focus.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: e)
        }
        // ⌘F by key code (a Russian layout sends another letter): the address field's editor would take it otherwise.
        if e.keyCode == 3 {
            find(nil)
            return true
        }
        guard e.charactersIgnoringModifiers?.lowercased() == "r" else { return super.performKeyEquivalent(with: e) }
        reload()
        return true
    }
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
