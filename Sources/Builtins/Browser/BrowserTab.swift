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
        web = WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        func b(_ sym: String, _ tip: String) -> NSButton {
            IconButton(.symbol(sym), tip: tip, target: nil, action: nil)
        }
        let back = b("chevron.left", String(localized: "Back")), fwd = b("chevron.right", String(localized: "Forward"))
        let reload = b("arrow.clockwise", String(localized: "Reload (⌘R)"))
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
        let bar = Bar.content([back, fwd, reload, address], [designButton, ext, more], stretching: address)
        let body = NSView()
        web.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(web)
        body.pin(ports)
        let box = BrowserBox()
        box.pin(stacked(bar, agentSlot, body))
        view = box
        super.init()
        box.reload = { [weak self] in self?.web.reload() }
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
        ports.onOpen = { [weak self] u in self?.load(u) }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.configuration.userContentController.add(WeakHandler(self), name: "kelp")
        address.delegate = self
        address.target = self
        address.action = #selector(go)
        back.target = web
        back.action = #selector(WKWebView.goBack(_:))
        fwd.target = web
        fwd.action = #selector(WKWebView.goForward(_:))
        reload.target = web
        reload.action = #selector(WKWebView.reload(_:))
        ext.target = self
        ext.action = #selector(openExternal)
        more.target = self
        more.action = #selector(showMore(_:))
        designButton.target = self
        designButton.action = #selector(toggleDesign)
        if agent { watch() }
        load(start)
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
            + (drive?.viewport.map { " · " + String(localized: "page \(Int($0.width))×\(Int($0.height))") } ?? "")
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
        if let viewport = drive?.viewport {
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
        load(address.stringValue)
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
        if let viewport = drive?.viewport {
            menu.add(String(localized: "Fill the Pane (the agent set \(Int(viewport.width))×\(Int(viewport.height)))"))
            { [weak self] in
                self?.drive?.viewport = nil
                self?.placeWeb()
            }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Reload Ignoring Cache")) { [weak self] in self?.web.reloadFromOrigin() }
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
        if webView.url?.absoluteString != "about:blank" { loadError = nil }   // the error page (about:blank) keeps it
        address.stringValue = webView.url?.absoluteString ?? ""
        ports.isHidden = true
        page = (webView.url, webView.title)
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
        address.stringValue = webView.url?.absoluteString ?? ""
        page = (webView.url, webView.title)
        if designOn { webView.evaluateJavaScript(Self.designJS(accent: .themeAccent)) }
        if drive != nil { webView.evaluateJavaScript(Self.watchJS) }   // a load begun before watch(): from now
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
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
        loadError =
            ns.localizedDescription
            + ((ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).map { " (\($0))" } ?? "")
        let text = ns.localizedDescription + " " + String(localized: "Is the dev server running?")
        web.loadHTMLString(EmptyStateView.html(String(localized: "Can't open this page"), text: text), baseURL: nil)
    }

}

/// Holds a browser tab. While the focus is in it (the page or its address), ⌘R reloads the page before the menu bar
/// gives it to Run, as in Safari; elsewhere ⌘R stays Run.
private final class BrowserBox: NSView {
    var reload: () -> Void = {}

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command, e.charactersIgnoringModifiers?.lowercased() == "r",
            let focus = window?.firstResponder as? NSView, focus.isDescendant(of: self)
        else {
            return super.performKeyEquivalent(with: e)
        }
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
