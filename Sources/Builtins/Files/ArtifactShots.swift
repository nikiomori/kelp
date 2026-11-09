import AppKit
import DesignKit
import WebKit

/// Pictures of pages for the Artifacts card, as Safari shows sites: each page laid out off screen at a desktop
/// window's width, its scripts off and its links going nowhere, and its top taken at the card's proportions. A live
/// page squeezed into the card laid out too narrow (boards cut off, columns crushed, a scroll bar). One page at a time:
/// a newer one replaces one still loading. Kept per page and version while the panel lives.
@MainActor
final class ArtifactShots: NSObject, WKNavigationDelegate {
    /// What a page is laid out in: a desktop window, at the card's proportions.
    static let page = NSSize(width: 1280, height: 802)
    /// A page that hasn't finished by then (a font or image that never comes) is taken as it is.
    private static let wait: TimeInterval = 5

    private let cache = NSCache<NSString, NSImage>()
    private var loading: (navigation: WKNavigation?, done: CheckedContinuation<Void, Never>)?
    /// Pictures asked for so far: one that isn't the last when its page is in gives way.
    private var asked = 0
    private lazy var web: WKWebView = {
        let web = WKWebView(frame: NSRect(origin: .zero, size: Self.page))   // off screen: no layout sizes it
        web.navigationDelegate = self
        return web
    }()

    /// The page's picture, as wide as the card; nil when it couldn't be drawn or a newer page came meanwhile.
    func picture(html: String, base: URL, key: String, dark: Bool, board: Bool) async -> NSImage? {
        let key = "\(key)|\(dark)" as NSString
        if let kept = cache.object(forKey: key) { return kept }
        finish()   // a page still loading gives way
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

    /// A Design canvas's board (the element in its `x-dc` past the `helmet`: 880 × 150, a phone's 390 × 844), all of
    /// it, for the card to fit whole; a page is taken at its top. Measured in Kelp's own world: the page's scripts stay
    /// off.
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
        guard let r = found as? [Double], r.count == 4, r[2] >= 40, r[3] >= 20 else { return top }
        return CGRect(x: r[0], y: r[1], width: min(r[2], 4000), height: min(r[3], r[2] * 2))
    }

    private func finish(_ navigation: WKNavigation? = nil) {
        guard let loading, navigation == nil || navigation === loading.navigation else { return }
        self.loading = nil
        loading.done.resume()
    }

    // The page's own scripts don't run; nothing takes it elsewhere (it's never on screen to be clicked).
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
