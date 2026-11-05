import AppKit
import WebKit
import Foundation
import Testing
import Markdown
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinFiles

/// A design or dashboard may be a cloned repository's: shown in Kelp its own scripts, inline handlers and frames don't run,
/// even behind a comment that once hid Kelp's policy (`<!--<head>-->`), and a meta refresh doesn't take the preview to a site,
/// while Kelp's own script beside the page runs and is the one heard.
@MainActor @Test(.timeLimit(.minutes(1))) func anHTMLPagesOwnScriptsDontRun() async throws {
    let page = #"<!--<head>--><!DOCTYPE html><html><head><title>t</title><meta http-equiv="refresh" content="0;url=https://example.com/">"#
        + #"</head><body onload="document.title='onload'"><script>document.title = 'ran'; webkit.messageHandlers.kelpSync?.postMessage('page')"#
        + #"</script><p>x</p><iframe srcdoc='<script>parent.document.body.dataset.frame = "ran"</script>'></iframe></body></html>"#
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let links = PreviewLinks(app: AppModel(builtins: Builtins.all)), heard = Heard()
    web.navigationDelegate = links
    web.configuration.userContentController.add(heard, contentWorld: MarkdownTab.world, name: "kelpSync")
    let base = FileManager.default.temporaryDirectory
    links.load(page, baseURL: base, scripts: ["document.body.dataset.kelp = 'yes'; webkit.messageHandlers.kelpSync.postMessage('kelp')"], world: MarkdownTab.world, in: web)
    func js(_ s: String) async -> String? { (try? await web.evaluateJavaScript(s, contentWorld: MarkdownTab.world)) as? String }
    for _ in 0..<100 where await js("document.readyState") != "complete" { try await Task.sleep(for: .milliseconds(50)) }
    try await Task.sleep(for: .seconds(1))   // the refresh, had it been let through
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
    links.load(html, baseURL: nil, scripts: [try #require(MarkdownHTML.mermaid(for: md, dark: false))], world: MarkdownTab.world, in: web)
    func js(_ s: String) async -> String? { (try? await web.evaluateJavaScript(s, contentWorld: MarkdownTab.world)) as? String }
    for _ in 0..<200 where await js("document.querySelector('.mermaid svg') ? 'drawn' : 'no'") != "drawn" {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await js("document.querySelector('.mermaid svg') ? 'drawn' : 'no'") == "drawn")
}

@MainActor private final class Heard: NSObject, WKScriptMessageHandler {
    var bodies: [String] = []
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { bodies.append(m.body as? String ?? "?") }
}
