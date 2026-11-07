import AppKit
import Foundation
import Markdown
import TestSupport
import Testing
import WebKit

@testable import BuiltinFiles
@testable import KelpApp
@testable import KelpKit

/// A design or dashboard may be a cloned repository's: shown in Kelp its own scripts, inline handlers and frames don't run,
/// even behind a comment that once hid Kelp's policy (`<!--<head>-->`), and a meta refresh doesn't take the preview to a site,
/// while Kelp's own script beside the page runs and is the one heard.
@MainActor @Test(.timeLimit(.minutes(1))) func anHTMLPagesOwnScriptsDontRun() async throws {
    let page =
        #"<!--<head>--><!DOCTYPE html><html><head><title>t</title><meta http-equiv="refresh" content="0;url=https://example.com/">"#
        + #"</head><body onload="document.title='onload'"><script>document.title = 'ran'; webkit.messageHandlers.kelpSync?.postMessage('page')"#
        + #"</script><p>x</p><iframe srcdoc='<script>parent.document.body.dataset.frame = "ran"</script>'></iframe></body></html>"#
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let links = PreviewLinks(app: AppModel(builtins: Builtins.all)), heard = Heard(), decided = Decided(links)
    web.navigationDelegate = decided
    web.configuration.userContentController.add(heard, contentWorld: MarkdownTab.world, name: "kelpSync")
    let base = FileManager.default.temporaryDirectory
    links.load(
        page, baseURL: base,
        scripts: ["document.body.dataset.kelp = 'yes'; webkit.messageHandlers.kelpSync.postMessage('kelp')"],
        world: MarkdownTab.world, in: web)
    func js(_ s: String) async -> String? {
        (try? await web.evaluateJavaScript(s, contentWorld: MarkdownTab.world)) as? String
    }
    #expect(try await waitFor(5) { !(await js("document.readyState") != "complete") })
    // The refresh is tried, and refused, rather than waited out.
    #expect(try await waitFor(10) { decided.refused.contains(where: { $0.hasPrefix("https://example.com") }) })
    #expect(decided.refused.contains { $0.hasPrefix("https://example.com") })
    #expect(await js("document.title") == "t")
    #expect(await js("document.body.dataset.kelp") == "yes")
    #expect(web.url?.absoluteString == base.absoluteString)
    #expect(heard.bodies == ["kelp"])
    #expect(await js("String(document.body.dataset.frame)") == "undefined")   // nor do its frames'
}

/// Kelp's own renderers still draw in a page whose scripts are off: mermaid's diagram, beside the page.
@MainActor @Test(.timeLimit(.minutes(1))) func mermaidDrawsBesideAScriptlessPage() async throws {
    let md = "```mermaid\ngraph LR\n  A --> B\n```"
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let links = PreviewLinks(app: AppModel(builtins: Builtins.all))
    web.navigationDelegate = links
    let html = MarkdownHTML.page(body: MarkdownHTML.render(md), baseURL: nil, dark: false)
    links.load(
        html, baseURL: nil, scripts: [try #require(MarkdownHTML.mermaid(for: md, dark: false))],
        world: MarkdownTab.world, in: web)
    func js(_ s: String) async -> String? {
        (try? await web.evaluateJavaScript(s, contentWorld: MarkdownTab.world)) as? String
    }
    #expect(try await waitFor(10) { await js("document.querySelector('.mermaid svg') ? 'drawn' : 'no'") == "drawn" })
}

/// What PreviewLinks decides, as it decides it: what it refused.
@MainActor private final class Decided: NSObject, WKNavigationDelegate {
    let links: PreviewLinks
    var refused: [String] = []
    init(_ links: PreviewLinks) { self.links = links }
    func webView(
        _ w: WKWebView, decidePolicyFor a: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        links.webView(w, decidePolicyFor: a, preferences: preferences) { [weak self] p, prefs in
            if p == .cancel { self?.refused.append(a.request.url?.absoluteString ?? "") }
            decisionHandler(p, prefs)
        }
    }
}

@MainActor private final class Heard: NSObject, WKScriptMessageHandler {
    var bodies: [String] = []
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        bodies.append(m.body as? String ?? "?")
    }
}
