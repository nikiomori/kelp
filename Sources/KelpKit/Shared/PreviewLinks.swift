import AppKit
import Core
import DesignKit
import WebKit
import WorkbenchKit

/// Links clicked in a rendered preview (Markdown, notebooks) open elsewhere instead of replacing the preview: web pages
/// in a browser tab, the repo's files in their own tab, and mail in the mail app. Jumps within the page (#heading) stay
/// in the page. Nothing else opens: the page may come from a cloned repository, and a link to its `tool.app` or to some
/// other app's URL scheme would run it (files from `git clone` carry no quarantine for Gatekeeper to check).
/// For the same reason, no code from the page itself runs (an agent's HTML page, a notebook's output). Its scripts are
/// off, Kelp's scripts run beside it in a world of their own (`load`), and its main frame stays on what Kelp loaded,
/// so no meta refresh or form can take it away.
@MainActor
package final class PreviewLinks: NSObject, WKNavigationDelegate {
    package enum Target: Equatable { case web(String), file(String), mail(URL), refused }
    private let app: AppModel
    /// What `load` showed last. It is the one place the main frame may go other than by a clicked link.
    private var shown = "about:blank"
    /// Whether the page shown may run scripts. Only a page Kelp made entirely may (a design's canvas), and its
    /// agent-written parts sit in frames sandboxed without scripts. WebKit draws no `srcdoc` frame while the page's
    /// scripts are off.
    private var pageScripts = false
    package init(app: AppModel) { self.app = app }
    /// Called when the page's process ended (it ran out of memory, or WebKit crashed): the page is gone from the view.
    package var onEnded: (() -> Void)?

    package func webViewWebContentProcessDidTerminate(_: WKWebView) { onEnded?() }

    /// Loads `html` as the preview's page. Kelp's `scripts` (JavaScript) run in `world`, in order, once the document is
    /// read. The tab's message handlers belong to that world, not to the page's.
    package func load(
        _ html: String, baseURL: URL?, scripts: [String] = [], world: WKContentWorld = .defaultClient,
        pageScripts: Bool = false, in web: WKWebView
    ) {
        self.pageScripts = pageScripts
        let uc = web.configuration.userContentController
        uc.removeAllUserScripts()
        for script in scripts {
            uc.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        }
        shown = baseURL.map(Self.sansFragment) ?? "about:blank"
        web.loadHTMLString(html, baseURL: baseURL)
    }

    package func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = pageScripts
        decisionHandler(policy(action, in: webView), preferences)
    }

    private func policy(_ action: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
        let url = action.request.url
        guard action.navigationType == .linkActivated, let url else {
            // The page's frames may load whatever they load (their scripts are off too), but the page itself stays.
            return action.targetFrame?.isMainFrame == false || url.map(Self.sansFragment) == shown ? .allow : .cancel
        }
        if url.fragment != nil, Self.sansFragment(url) == webView.url.map(Self.sansFragment) { return .allow }
        Self.open(url, in: app)
        return .cancel
    }

    /// Opens a clicked link by its `target`. A web page opens as a browser tab and a file as a tab (asking first with
    /// `ask` when it's outside the projects, as a `kelp://` link does). Mail opens in Mail, and anything else is
    /// refused.
    package static func open(_ url: URL, in app: AppModel, ask: (@MainActor (String) async -> Bool)? = nil) {
        switch target(url) {
        case .web(let address): app.workbench.open(address)
        case .file(let path):
            KelpLinks(app).whenAllowed(path, ask: ask ?? KelpLinks.askToOpen) { app.workbench.open(TabURI.file(path)) }
        case .mail(let mail): openOutside(mail)
        case .refused: refuse(url)
        }
    }

    /// The one place Kelp hands a URL to macOS to open in another app (ArchitectureTests enforces that). It opens a web
    /// page, mail, or a pane of System Settings. A file, an app or another app's scheme could run something, so those
    /// are refused.
    package static func openOutside(_ url: URL) {
        guard opensOutside(url) else { return refuse(url) }
        NSWorkspace.shared.open(url)
    }
    static func opensOutside(_ url: URL) -> Bool {
        ["http", "https", "mailto", "x-apple.systempreferences"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Says why nothing opened, with the link to copy. A terminal's links follow the same rules (`target`).
    private static func refuse(_ url: URL) {
        Banner.show(
            String(localized: "Kelp opens links to web pages and files only, not “\(url.absoluteString)”."),
            action: (
                String(localized: "Copy Link"),
                {
                    copyText(url.absoluteString)
                }
            ))
    }

    package static func target(_ url: URL) -> Target {
        switch url.scheme?.lowercased() {
        case "http", "https": return .web(url.absoluteString)
        case "mailto": return .mail(url)
        case "file" where isPlainFile(url.resolvingSymlinksInPath()): return .file(url.resolvingSymlinksInPath().path)
        // A remote project's file is on its host, so its tab reads it from there, and nothing here runs.
        case "file" where Remotes(home: Paths.root).containing(url.standardizedFileURL.path) != nil:
            return .file(url.standardizedFileURL.path)
        default: return .refused
        }
    }

    /// Whether the URL is a regular file, so not a folder, an app or any other bundle (which the Finder would launch).
    private static func isPlainFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func sansFragment(_ url: URL) -> String { url.absoluteString.components(separatedBy: "#")[0] }
}
