import Core
import Foundation
import Markdown
import Testing

@testable import BuiltinFiles

/// A review's page: each option a button that says which point and letter it is, the picked one marked, Send off
/// until something is picked. `KELP_REVIEW_HTML=<dir>` also writes the page in both themes, to look at.
@Test func reviewPageShowsPicksAndSend() throws {
    let text = """
        # GRDB 7: four decisions

        Pick one in each; your picks come back to me.

        ## 1. Records that lose their implicit defaults
        - [x] A. Write defaults into each `init(from:)` *recommended*
          Nine small edits; decoding stays strict.
        - [ ] B. A migration that fills the columns once

        ## 2. What the test opens <script>
        - [ ] A. A scrubbed copy of a real 0.9 database *recommended*
        - [ ] B. Fixtures generated in the test
        > Note: CI has no "real" database
        """
    let body = ReviewPage.body(Review(text), sendTo: "GRDB 7 plan")
    #expect(body.contains(#"class="k-opt on" aria-pressed="true" data-p="1" data-k="A""#))
    #expect(body.contains(#"data-p="2" data-k="B""#) && body.contains("<code>init(from:)</code>"))
    #expect(body.contains(#"value="CI has no &quot;real&quot; database""#) && !body.contains("<script>"))
    #expect(body.contains(#"<span class="k-sum">1A · 1 of 2</span>"#) && body.contains("Recommended for the Rest"))
    #expect(body.contains(#"class="k-send" title="⌘↩">Send to GRDB 7 plan</button>"#))
    #expect(
        ReviewPage.body(Review("# T\n\n## 1. Q\n- [ ] A. a\n"), sendTo: nil).contains(
            "class=\"k-send\" title=\"⌘↩\" disabled"))
    let sent = ReviewPage.body(Review(Review.markSent(text, at: "12:04")), sendTo: "Codex")
    #expect(sent.contains("Change Answers") && sent.contains(#"class="k-opt dim""#) && !sent.contains("k-send"))

    if let dir = ProcessInfo.processInfo.environment["KELP_REVIEW_HTML"] {
        for dark in [false, true] {
            let html = MarkdownHTML.page(body: body, baseURL: nil, dark: dark) + ReviewPage.style
            try html.write(toFile: "\(dir)/review-\(dark ? "dark" : "light").html", atomically: true, encoding: .utf8)
        }
    }
}
