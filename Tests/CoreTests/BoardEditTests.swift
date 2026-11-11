import Foundation
import Testing

@testable import Core

private let board = """
    <section class="screen" data-id="welcome">
      <h1 class="title" data-id="title">Welcome &amp; hello</h1>
      <p>Open a folder.</p>
      <p>Open a folder.</p>
      <button class="button" data-id="start" style="padding: 8px; gap: 4px">Start</button>
      <div data-id="card"><span>inside</span></div>
    </section>
    """

@Test func textTypedOnABoardReplacesOnlyThatElements() throws {
    let out = try #require(BoardEdit.setText(board, id: "title", old: "Welcome & hello", new: "Hi <you>"))
    #expect(out.contains(#"data-id="title">Hi &lt;you&gt;</h1>"#))
    #expect(out.replacingOccurrences(of: "Hi &lt;you&gt;", with: "Welcome &amp; hello") == board)
    #expect(BoardEdit.setText(board, id: "title", old: "Something else", new: "x") == nil, "the file changed since")
    #expect(BoardEdit.setText(board, id: "card", old: "inside", new: "x") == nil, "not an element of text alone")
    #expect(BoardEdit.setText(board, id: nil, old: "Open a folder.", new: "x") == nil, "twice: which one?")
    #expect(BoardEdit.setText(board, id: nil, old: "Start", new: "Go")?.contains(">Go</button>") == true)
}

@Test func aStyleSetOnABoardGoesIntoItsElementsStyle() throws {
    let added = try #require(BoardEdit.setStyle(board, id: "title", property: "color", value: "var(--accent)"))
    #expect(added.contains(#"<h1 class="title" data-id="title" style="color: var(--accent)">"#))
    let changed = try #require(BoardEdit.setStyle(board, id: "start", property: "padding", value: "var(--space-4)"))
    #expect(changed.contains(#"style="gap: 4px; padding: var(--space-4)">Start"#))
    let removed = try #require(BoardEdit.setStyle(board, id: "start", property: "gap", value: nil))
    #expect(removed.contains(#"data-id="start" style="padding: 8px">"#))
    #expect(BoardEdit.setStyle(board, id: "start", property: "color", value: "red\"><script>") == nil)
    #expect(BoardEdit.setStyle(board, id: "nope", property: "color", value: "red") == nil)
    #expect(
        DesignSystem.names(tokens: ##"{"color": {"bg": "#fff", "accent": "#000"}, "space": {"4": "16px"}}"##)
            == ["color": ["accent", "bg"], "space": ["4"]])
}
