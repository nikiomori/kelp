import AppKit
import Core
import DesignKit
import KelpKit
import WebKit
import WorkbenchKit

/// Handles what the page's loads tell the tab, and the address bar's completion of what's typed. A commit or a finish
/// shows the page, a failure shows why in the page's place, and an agent driving the page hears its address and status.
extension BrowserTab {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        drive?.nameDocument += 1
        drive?.names.removeAll()
        if webView.url?.absoluteString != "about:blank" {   // the error page (about:blank) keeps the failure
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
        if drive != nil { webView.evaluateJavaScript(Self.watchJS) }   // a load begun before watch(): watch it from now
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }
    /// Reloads the page when WebKit's page process quits (a crash, memory pressure), because the pane stays white until
    /// something loads again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if drive != nil { noteLog("[page] the page’s process ended; loaded again") }
        reloadPage()
    }
    func showError(_ error: Error) {
        let ns = error as NSError
        // A navigation cancelled by the next one (a click or Back while loading) and a download handed off aren't
        // failures. Showing the error page for them cancelled the navigation the user had just started.
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
        web.loadHTMLString(EmptyStateView.html(String(localized: "Can’t Open This Page"), text: text), baseURL: nil)
    }

    /// Completes the address as it's typed from the pages visited (`BrowserHistory`), with the completed part selected,
    /// as Safari does.
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
}

extension BrowserTab {
    /// What Safari adds to WebKit's user agent. Without it sites take the page for an unknown browser and serve it
    /// their fallback layout (old Google, "browser not supported").
    static let safariName: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(safari ?? "26.0") Safari/605.1.15"
    }()
}
