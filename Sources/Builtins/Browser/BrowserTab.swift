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
    let address = NSTextField()
    let designButton = PointerButton(frame: .zero)
    /// The workspace's servers, shown instead of a blank page.
    let ports: PortsView
    let app: AppModel
    var designOn = false
    @ObservationIgnored var clicks = DesignClicks()
    @ObservationIgnored var clickWatch: Any?
    /// Views for the tab of an agent's page that also holds its subagents' pages (BrowserPages.swift). `switchSlot`
    /// holds the row that switches between the pages, over `pageArea`, which holds this page's own content and the
    /// subagents' pages. On a subagent's page, `host` is the tab the page is in.
    let switchSlot = NSView(), pageArea = NSView()
    @ObservationIgnored private(set) lazy var switchHeight = switchSlot.heightAnchor.constraint(equalToConstant: 0)
    @ObservationIgnored private(set) var ownContent = NSView()
    @ObservationIgnored private(set) lazy var pageSet = PageSet(host: self)
    @ObservationIgnored weak var host: BrowserTab?
    /// The user's clicks and keys in the page while an agent drives it (`watchUser`).
    @ObservationIgnored var userWatch: Any?
    /// The file of a local page (`preview:/path/page.html`), shown as the browser sees it and reloaded whenever a file
    /// next to it changes.
    private var previewFile: String? { start.hasPrefix("preview:") ? String(start.dropFirst("preview:".count)) : nil }
    private var watcher: FileWatcher?
    /// The page's address and title as of its last commit or load. What the tab shows follows these.
    private var page: (url: URL?, title: String?) = (nil, nil)
    var uri: String {
        let shown = previewFile != nil ? start : page.url?.absoluteString ?? start
        guard agent else { return shown }
        return TabURI.agentPage(shown.isEmpty && pageSet.ownOpened ? "about:blank" : shown, session: ownerSession)
    }
    let start: String
    let ownerSession: String?
    /// Whether this is an agent's page (`kelp browser open`), with its own website data store.
    let agent: Bool
    /// Why the last load failed, until the next one commits (`kelp browser` says it).
    var loadError: String?
    /// The address that failed, while its error page shows; the bar, the tab and Reload keep to it, not to about:blank.
    var failed: URL?
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []
    /// The find card for ⌘F (BrowserFind.swift), made the first time it is needed.
    @ObservationIgnored var finding: FindCard?
    /// The workspace's servers, watched while a local address failed, so the page loads again once its port is served.
    @ObservationIgnored lazy var serving = Watched(.ports, in: app)
    /// How far the page has loaded, as a line under the bar while it loads, its fill read when its layer updates.
    @ObservationIgnored private let progress = FillStack()
    @ObservationIgnored private lazy var progressWidth = progress.widthAnchor.constraint(equalToConstant: 0)
    /// The page's size, set by the user (⋯ › Page Size) or the agent (`kelp browser viewport`). The page sits at that
    /// size at the top of the pane, centred across. Nil means the page fills the pane (`placeWeb`).
    @ObservationIgnored var viewport: CGSize?
    /// Set when the user's typing in the address bar removed text, so no completion is offered for it.
    @ObservationIgnored var deleting = false
    private let back = IconButton(.symbol("chevron.left"), tip: String(localized: "Back"), target: nil, action: nil)
    private let forward = IconButton(
        .symbol("chevron.right"), tip: String(localized: "Forward"), target: nil, action: nil)
    private let reload = IconButton(
        .symbol("arrow.clockwise"), tip: String(localized: "Reload (⌘R)"), target: nil, action: nil)
    /// This page's id among the pages agents drive (`AgentPages`).
    let pageId = UUID().uuidString
    /// What `kelp browser` keeps on this tab once an agent drives the page (`watch()`). It is nil on a page only the
    /// user browses.
    @ObservationIgnored var drive: AgentDrive?
    /// The downloads under way (BrowserDownloads.swift), with each download's destination, source and page.
    @ObservationIgnored var downloading: [ObjectIdentifier: (to: URL, source: URL?, page: URL?)] = [:]
    /// When WebKit last decided a navigation is a download with no destination yet. An action's answer waits for the
    /// download (5 s at most, in case it never starts), since on a busy Mac it can begin after the answer's first look.
    @ObservationIgnored var downloadDecided: Date?
    var downloadComing: Bool { downloadDecided.map { Date().timeIntervalSince($0) < 5 } ?? false }
    /// The bar under the toolbar once an agent drives the page. It says that an agent drives the page, with Take Over
    /// or Hand Back. It has no height until then.
    @ObservationIgnored private let agentSlot = NSView()
    @ObservationIgnored private lazy var agentSlotHeight = agentSlot.heightAnchor.constraint(equalToConstant: 0)
    @ObservationIgnored private let agentLabel = NSTextField(labelWithString: "")
    @ObservationIgnored private let agentIcon = NSImageView(image: .symbol("cursorarrow.motionlines"))
    @ObservationIgnored private let agentButton = PointerButton()
    /// The recording of the page in progress (BrowserRecording.swift), and the file the last recording went to.
    @ObservationIgnored var recording: PageRecording?
    @ObservationIgnored var lastRecording: URL?
    /// The bar's button that shows the page is being recorded (by the user or an agent) and stops the recording.
    let recordButton = IconButton(
        .symbol("record.circle"), tip: String(localized: "Stop Recording"), target: nil, action: nil)
    /// The host before the address, on a page an agent there drives (BrowserHostPage.swift).
    @ObservationIgnored let hostChip = PointerButton(title: "") {}
    @ObservationIgnored private var webFill: [NSLayoutConstraint] = []
    @ObservationIgnored private var webFixed: [NSLayoutConstraint] = []
    /// The page this tab shows now: its own, or a subagent's (`pageSet`).
    var shownPage: BrowserTab { agent ? pageSet.shownTab : self }

    var title: String {
        let pages = agent && !pageSet.pages.isEmpty ? " +\(pageSet.pages.count)" : ""
        return ownTitle + pages
    }
    private var ownTitle: String {
        previewFile.map { ($0 as NSString).lastPathComponent } ?? page.title.flatMap { $0.isEmpty ? nil : $0 } ?? page
            .url?.host
            ?? String(localized: "New Page")
    }
    var icon: NSImage? { .symbol(previewFile == nil ? "safari" : "eye") }
    var toolTip: String? {
        page.url.map {
            agent
                ? String(localized: "\($0.absoluteString)\nAn agent’s page: cookies and storage of its own")
                : $0.absoluteString
        }
    }

    init(uri: String, app: AppModel) {
        agent = TabURI.scheme(uri) == TabURI.agentScheme
        ownerSession = TabURI.agentPageSession(uri)
        start = TabURI.pageURL(uri)
        self.app = app
        ports = PortsView(app: app)
        let cfg = WKWebViewConfiguration()
        if agent {
            let session = ownerSession.flatMap(app.session)
            cfg.websiteDataStore = app.part { BrowserDataStores() }.store(
                owner: session?.isAgent == true ? session?.id : nil)
        }
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.applicationNameForUserAgent = Self.safariName
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")   // "Inspect Element" in the page's context menu
        // A window the user's page opened (BrowserDialogs.swift) was made by WebKit, with the opener's cookies and a
        // `window.opener`, and WebKit is loading it already.
        let opened = agent ? nil : BrowserTab.opened.removeValue(forKey: start)
        web = opened ?? WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        let browser = Self.defaultBrowser()
        let ext = IconButton(browser?.icon ?? .symbol("safari"), tip: Self.openIn(browser), target: nil, action: nil)
        let more = IconButton(
            .symbol("ellipsis.circle"), tip: String(localized: "More Actions"), target: nil, action: nil)
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
                "Design Mode: click an element to send its source, HTML, CSS and a screenshot to the agent (⌥-click copies them, ⇧-click copies its picture for an artifact's mark)"
        )
        recordButton.contentTintColor = .systemRed
        recordButton.isHidden = true
        let bar = Bar.content(
            [back, forward, reload, hostChip, address], [recordButton, designButton, ext, more], stretching: address)
        let body = NSView()
        web.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(web)
        body.pin(ports)
        progress.fill = .themeAccent
        progress.alphaValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(progress)
        let box = BrowserBox()
        ownContent = stacked(bar, agentSlot, body)
        pageArea.pin(ownContent)
        box.pin(stacked(switchSlot, pageArea))
        view = box
        super.init()
        box.reload = { [weak self] in self?.shownPage.reloadPage() }
        box.find = { [weak self] in self?.shownPage.find($0) }
        agentSlotHeight.isActive = true
        switchHeight.isActive = true
        webFill = [
            web.topAnchor.constraint(equalTo: body.topAnchor), web.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: body.trailingAnchor)
        ]
        // A page wider than the pane starts at the pane's left edge and is cut on the right. A page taller than the
        // pane is cut at the bottom.
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
        recordButton.target = self
        recordButton.action = #selector(saveRecording)
        showHostChip()
        if agent { watch() }
        track(owner: self) { [weak self] in
            self?.failedServed ?? false
        } changed: { [weak self] served in
            if served { self?.reloadPage() }
        }
        if opened != nil {
            ports.isHidden = true
            showPage()
        } else if !agent || ownerSession != nil || previewFile != nil {
            // Legacy agent web addresses have no record of which network they were opened on.
            load(start)
        }
    }

    isolated deinit {
        AgentPages.of(app).closed(pageId)
        stopWatchingUser()
    }

    /// Whether the local address that failed is served now, because its dev server started in this screen.
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
            agentIcon.symbolConfiguration = .chrome()
            agentLabel.font = .ui(TextSize.row)
            agentLabel.lineBreakMode = .byTruncatingTail
            agentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            agentButton.padding = Metrics.gap
            agentButton.restFill = .fillRest
            agentButton.onClick = { [weak self] in self?.toggleTakeOver() }
            agentSlot.pinBottom(Bar.content([agentIcon, agentLabel], [agentButton]))
            agentSlot.reveal(agentSlotHeight, open: true)   // the page under it moves down, as the pages' row does
            watchUser()
        }
        let asked = drive?.asked?.text, takenOver = drive?.takenOver == true
        AgentPages.of(app).change(pageId) { $0.holder = asked.map { .asked($0) } ?? (takenOver ? .user : .agent) }
        let look = stripLook()
        agentLabel.stringValue =
            look.text + (viewport.map { " · " + String(localized: "page \(Int($0.width))×\(Int($0.height))") } ?? "")
        // The agent's question waits for the user, so it is orange, as on its row and in its card.
        agentLabel.textColor = asked != nil ? .textOrange : takenOver ? .labelColor : .secondaryLabelColor
        agentIcon.contentTintColor = asked != nil ? .textOrange : .secondaryLabelColor
        agentButton.title = look.button
        agentButton.toolTip = look.tip
    }

    private func toggleTakeOver() {
        if drive?.asked != nil { return done() }
        drive?.takenOver.toggle()
        showAgentBar()
    }

    /// Lays out the page at the size set in `viewport`, or filling the pane.
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

    /// Makes the bar follow the page as WebKit changes it (KVO, delivered on the main thread). Back and Forward are
    /// enabled only when there's a page that way, and Reload turns into Stop while loading. A single-page app's own
    /// changes of address and title (pushState, document.title) reach the bar and the tab, not just loads.
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
        progress.needsDisplay = true   // reads the accent again, which light/dark or a theme may have changed
        if loading, progress.alphaValue == 0 { progressWidth.constant = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(loading ? Motion.fast : Motion.disappear)
            progressWidth.animator().constant = width * (loading ? web.estimatedProgress : 1)
            progress.animator().alphaValue = loading && web.estimatedProgress < 1 ? 1 : 0
        }
    }

    /// Shows the page's address and title in the bar and the tab. The bar keeps what the user is typing in it.
    func showPage() {
        let blank = web.url?.absoluteString == "about:blank"
        guard let url = blank ? failed ?? web.url : web.url else { return }
        page = (url, blank ? nil : web.title)
        if address.currentEditor() == nil, previewFile == nil { address.stringValue = url.absoluteString }
        showDriven()
    }

    @objc private func reloadOrStop() {
        if web.isLoading { web.stopLoading() } else { reloadPage() }
    }

    /// Reloads the page, or on the error page tries the failed address again (a dev server may have started since).
    func reloadPage(fromOrigin: Bool = false) {
        if let failed {
            web.load(URLRequest(url: failed))
        } else if fromOrigin {
            web.reloadFromOrigin()
        } else {
            web.reload()
        }
    }

    func focus() {
        if web.url == nil { view.window?.makeFirstResponder(address) } else { view.window?.makeFirstResponder(web) }
    }

    func load(_ raw: String) {
        guard !awaitsHostNetwork else { return }
        if let previewFile, raw == start {
            let fileURL = URL(fileURLWithPath: previewFile), dir = fileURL.deletingLastPathComponent()
            web.loadFileURL(fileURL, allowingReadAccessTo: dir)
            address.stringValue = fileURL.absoluteString
            watcher = FileWatcher(root: dir.path) { [weak self] _ in MainActor.assumeIsolated { _ = self?.web.reload() }
            }   // FileWatcher delivers on the main thread
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

    /// What Safari adds to WebKit's user agent. Without it sites take the page for an unknown browser and serve it
    /// their fallback layout (old Google, "browser not supported").
    static let safariName: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(safari ?? "26.0") Safari/605.1.15"
    }()
}
