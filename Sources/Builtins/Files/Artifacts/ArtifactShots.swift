import AppKit
import DesignKit
import WebKit

/// Takes pictures of pages for the Artifacts card, the way Safari shows sites. Each page is laid out off screen at a
/// desktop window's width, with its scripts off and its links going nowhere, and its top is taken at the card's
/// proportions. A live page squeezed into the card was laid out too narrow (boards cut off, columns crushed, a scroll
/// bar). Only one page loads at a time, so a newer request replaces one still loading. Pictures are cached per page
/// and version while the panel lives.
@MainActor
final class ArtifactShots: NSObject, WKNavigationDelegate {
    /// The size a page is laid out at: a desktop window, at the card's proportions.
    static let page = NSSize(width: 1280, height: 802)
    /// When a page hasn't finished loading by then (a font or image never comes), its picture is taken as it is.
    private static let wait: TimeInterval = 5

    private let cache = NSCache<NSString, NSImage>()
    private var loading: (navigation: WKNavigation?, done: CheckedContinuation<Void, Never>)?
    /// How many pictures have been asked for. When a page has loaded, a request that is no longer the latest gives up.
    private var asked = 0
    private lazy var web: WKWebView = {
        let web = WKWebView(frame: NSRect(origin: .zero, size: Self.page))   // off screen, so no layout sizes it
        web.navigationDelegate = self
        return web
    }()

    /// Returns the page's picture, as wide as the card. Returns nil when it couldn't be drawn, or when a newer page was
    /// asked for meanwhile.
    func picture(html: String, base: URL, key: String, dark: Bool, board: Bool) async -> NSImage? {
        let key = "\(key)|\(dark)" as NSString
        if let kept = cache.object(forKey: key) { return kept }
        finish()   // a page still loading is given up
        asked += 1
        let mine = asked
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await withCheckedContinuation { done in
            loading = (web.loadHTMLString(html, baseURL: base), done)
            let navigation = loading?.navigation
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wait) { [weak self] in
                // asyncAfter on the main queue
                MainActor.assumeIsolated { if self?.loading?.navigation === navigation { self?.finish() } }
            }
        }
        guard mine == asked else { return nil }
        let shot = WKSnapshotConfiguration()
        shot.rect = board ? await boardRect() : CGRect(origin: .zero, size: Self.page)
        shot.snapshotWidth = NSNumber(value: Double(ArtifactCard.size.width))
        do {
            let image = try await web.takeSnapshot(configuration: shot)
            cache.setObject(image, forKey: key)
            return image
        } catch { return nil }
    }

    /// Returns the rect of a Design canvas's board, so the card can fit the whole board. The board is the first element
    /// in `x-dc` that isn't the `helmet` (880 × 150, or 390 × 844 for a phone). Other pages are taken at their top.
    /// The board is measured in Kelp's own script world, so the page's own scripts stay off.
    private func boardRect() async -> CGRect {
        let top = CGRect(origin: .zero, size: Self.page)
        let found: Any?
        do {
            found = try await web.callAsyncJavaScript(
                """
                const e = document.querySelector('x-dc > :not(helmet, script, style)')
                  ?? document.body.firstElementChild
                if (!e) return null
                const r = e.getBoundingClientRect()
                return [r.left, r.top, r.width, r.height]
                """, contentWorld: .defaultClient)
        } catch { return top }
        guard let rect = found as? [Double], rect.count == 4, rect[2] >= 40, rect[3] >= 20 else { return top }
        return CGRect(x: rect[0], y: rect[1], width: min(rect[2], 4000), height: min(rect[3], rect[2] * 2))
    }

    private func finish(_ navigation: WKNavigation? = nil) {
        guard let loading, navigation == nil || navigation === loading.navigation else { return }
        self.loading = nil
        loading.done.resume()
    }

    // The page's own scripts don't run, and nothing navigates it elsewhere (it's never on screen to be clicked).
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = false
        decisionHandler(action.navigationType == .other ? .allow : .cancel, preferences)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(navigation) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(navigation)
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) { finish(navigation) }
}
