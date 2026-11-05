import AppKit
import WebKit
import Foundation
import Testing
@testable import BuiltinFiles

/// A design or dashboard may be a cloned repository's: shown in Kelp its own scripts and inline handlers don't run, while
/// what Kelp adds after it with the nonce (scroll place, Ask Agent) does.
@MainActor @Test(.timeLimit(.minutes(1))) func anHTMLPagesOwnScriptsDontRun() async throws {
    let page = #"<!DOCTYPE html><html><head><title>t</title></head><body onload="document.title='onload'">"#
        + #"<script>document.title = 'ran'</script><p>x</p></body></html>"#
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    web.loadHTMLString(MarkdownTab.scriptless(page, nonce: "n1") + #"<script nonce="n1">document.body.dataset.kelp = "yes"</script>"#,
                       baseURL: FileManager.default.temporaryDirectory)
    func js(_ s: String) async -> String? { (try? await web.evaluateJavaScript(s)) as? String }
    for _ in 0..<100 where await js("document.readyState") != "complete" { try await Task.sleep(for: .milliseconds(50)) }
    #expect(await js("document.title") == "t")
    #expect(await js("document.body.dataset.kelp") == "yes")
    #expect(MarkdownTab.scriptless("<p>bare</p>", nonce: "n").hasPrefix("<meta http-equiv"))
}
