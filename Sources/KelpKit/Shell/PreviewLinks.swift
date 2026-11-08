import AppKit
import WebKit
import WorkbenchKit

/// Links clicked in a rendered preview (Markdown, notebooks) open elsewhere instead of replacing the preview: web
/// pages in a browser tab, the repo's files in their own tab, mail in the mail app. Jumps within the page (#heading)
/// stay. Nothing else opens: the page may come from a cloned repository, and a link to its `tool.app` or to some other
/// app's scheme would run it (files from `git clone` carry no quarantine for Gatekeeper to check).
/// For the same reason nothing of the page's own runs (an agent's page of HTML, a notebook's output): its scripts are off,
/// Kelp's run beside it in a world of their own (`load`), and its main frame stays on what Kelp loaded (no meta refresh
/// or form takes it away).
@MainActor
package final class PreviewLinks: NSObject, WKNavigationDelegate {
    package enum Target: Equatable { case web(String), file(String), mail(URL), refused }
    private let app: AppModel
    /// What `load` showed last: the one place the main frame may go but by a clicked link.
    private var shown = "about:blank"
    package init(app: AppModel) { self.app = app }

    /// `html` as the preview's page; Kelp's `scripts` (JavaScript) run in `world` once its document is read, in order. That
    /// world, not the page's, is where the tab's message handlers belong.
    package func load(
        _ html: String, baseURL: URL?, scripts: [String] = [], world: WKContentWorld = .defaultClient, in web: WKWebView
    ) {
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
        preferences.allowsContentJavaScript = false
        decisionHandler(policy(action, in: webView), preferences)
    }

    private func policy(_ action: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
        let url = action.request.url
        guard action.navigationType == .linkActivated, let url else {
            // A page's frames load what they load (their scripts are off too); the page itself stays.
            return action.targetFrame?.isMainFrame == false || url.map(Self.sansFragment) == shown ? .allow : .cancel
        }
        if url.fragment != nil, Self.sansFragment(url) == webView.url.map(Self.sansFragment) { return .allow }
        Self.open(url, in: app)
        return .cancel
    }

    /// A clicked link, by `target`: a web page as a browser tab, a file as a tab (asking first when it's outside the
    /// projects, as a `kelp://` link does: `ask`), mail in Mail, anything else refused.
    package static func open(_ url: URL, in app: AppModel, ask: (@MainActor (String) async -> Bool)? = nil) {
        switch target(url) {
        case .web(let address): app.workbench.open(address)
        case .file(let path):
            KelpLinks(app).whenAllowed(path, ask: ask ?? KelpLinks.askToOpen) { app.workbench.open(TabURI.file(path)) }
        case .mail(let mail): openOutside(mail)
        case .refused: refuse(url)
        }
    }

    /// The one place Kelp hands a URL to macOS to open in another app (ArchitectureTests holds it to that): a web page,
    /// mail, a pane of System Settings. A file, an app or another app's scheme could run something, so it's refused.
    package static func openOutside(_ url: URL) {
        guard opensOutside(url) else { return refuse(url) }
        NSWorkspace.shared.open(url)
    }
    static func opensOutside(_ url: URL) -> Bool {
        ["http", "https", "mailto", "x-apple.systempreferences"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Says why nothing opened, with the link to copy (a terminal's links go by the same rules: `target`).
    private static func refuse(_ url: URL) {
        Banner.show(
            String(localized: "Kelp opens links to web pages and files only, not “\(url.absoluteString)”."),
            action: (
                String(localized: "Copy Link"),
                {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            ))
    }

    package static func target(_ url: URL) -> Target {
        switch url.scheme?.lowercased() {
        case "http", "https": return .web(url.absoluteString)
        case "mailto": return .mail(url)
        case "file" where isPlainFile(url.resolvingSymlinksInPath()): return .file(url.resolvingSymlinksInPath().path)
        default: return .refused
        }
    }

    /// A regular file: not a folder, and so not an app or any other bundle (which the Finder would launch).
    private static func isPlainFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func sansFragment(_ url: URL) -> String { url.absoluteString.components(separatedBy: "#")[0] }
}
