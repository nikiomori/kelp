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

@Test func aSceneTimeIsSetOnItsElement() throws {
    let page = #"<div class="scene" data-id="intro" data-start="0" data-duration="2"><h1 data-id="t">Hi</h1></div>"#
    let moved = try #require(BoardEdit.setAttribute(page, id: "intro", name: "data-start", value: "0.5"))
    #expect(moved.contains(#"data-start="0.5" data-duration="2""#))
    let added = try #require(BoardEdit.setAttribute(page, id: "t", name: "data-start", value: "1"))
    #expect(added.contains(#"<h1 data-id="t" data-start="1">"#))
    #expect(BoardEdit.setAttribute(page, id: "intro", name: "style", value: "x") == nil, "only data- attributes")
    #expect(BoardEdit.setAttribute(page, id: "intro", name: "data-start", value: "1\"><script>") == nil)
}

/// An element taken out leaves no empty line; one copied comes right after it, its data-ids and those inside it
/// numbered so each stays one of a kind.
@Test func anElementIsTakenOutOrCopiedWhole() throws {
    let page = "<div data-id=\"a\">\n  <p data-id=\"t\">Hi <b>x</b></p>\n  <img data-id=\"i\" src=\"a.png\">\n</div>"
    #expect(BoardEdit.remove(page, id: "t") == "<div data-id=\"a\">\n  <img data-id=\"i\" src=\"a.png\">\n</div>")
    #expect(BoardEdit.remove(page, id: "i") == "<div data-id=\"a\">\n  <p data-id=\"t\">Hi <b>x</b></p>\n</div>")
    let copied = try #require(BoardEdit.duplicate(page, id: "t"))
    #expect(copied.id == "t-2")
    #expect(copied.text.contains("<p data-id=\"t\">Hi <b>x</b></p>\n  <p data-id=\"t-2\">Hi <b>x</b></p>"))
    let whole = try #require(BoardEdit.duplicate(copied.text, id: "a"))
    // t-2 is taken, so the whole copy takes the next number free for all its ids
    #expect(whole.id == "a-3" && whole.text.contains("data-id=\"t-2-3\"") && whole.text.contains("data-id=\"t-3\""))
    #expect(BoardEdit.setAttribute(page, id: "i", name: "src", value: "b.png")?.contains("src=\"b.png\"") == true)
    #expect(BoardEdit.remove(page, id: "none") == nil)
    let hidden = try #require(BoardEdit.setAttribute(page, id: "t", name: "data-hidden", value: "true"))
    #expect(BoardEdit.setAttribute(hidden, id: "t", name: "data-hidden", value: nil) == page)
    let stage = #"<body data-width="1920" data-height="1080"><p data-id="t">x</p></body>"#
    #expect(
        BoardEdit.setAttribute(stage, id: nil, name: "data-width", value: "1080")
            == #"<body data-width="1080" data-height="1080"><p data-id="t">x</p></body>"#)
}

/// An element without a data-id gets one, found as the nth of its tag in the page's body; the id is new.
@Test func anElementWithoutAnIDGetsOne() throws {
    let page = #"<html><head><style>p{}</style></head><body><p>a</p><P data-id="p-1">b</P><p>c</p></body></html>"#
    let given = try #require(BoardEdit.giveID(page, tag: "p", index: 2))
    #expect(given.id == "p-2")
    #expect(given.text.contains(#"<p data-id="p-2">c</p>"#))
    #expect(BoardEdit.giveID(page, tag: "p", index: 3) == nil)
    #expect(BoardEdit.giveID(given.text, tag: "p", index: 2)?.text == given.text, "one that has an id keeps it")
    #expect(BoardEdit.giveID(page, tag: "p\"", index: 0) == nil)
    #expect(BoardEdit.freeID(page, "p") == "p-2")
    #expect(BoardEdit.appendToBody("<body><p>a</p></body>", "<img>") == "<body><p>a</p><img>\n</body>")
    #expect(BoardEdit.appendToBody("<p>a</p>", "<img>") == "<p>a</p><img>\n")
}

/// Words styled by hand go inside their element; only spans, b, i, u, strong, em and br with a style are taken.
@Test func styledWordsGoInsideTheirElement() {
    let page = #"<h1 data-id="t" class="big">Каждый день</h1>"#
    let html = #"<span style="color: var(--accent)">Каждый</span> <b>день</b>"#
    #expect(BoardEdit.setInner(page, id: "t", html: html) == #"<h1 data-id="t" class="big">"# + html + "</h1>")
    #expect(BoardEdit.setInner(page, id: "t", html: "<script>x()</script>") == nil)
    #expect(BoardEdit.setInner(page, id: "t", html: #"<span onclick="x()">a</span>"#) == nil)
    #expect(BoardEdit.setInner(page, id: "none", html: "a") == nil)
}

/// A font brought into a page is an @font-face in its first style, a new style before </head>, or one at a board's
/// start; a name that could end the rule is refused.
@Test func aFontIsBroughtIntoThePage() {
    let face = "@font-face { font-family: 'Grotesk'; src: url('G.woff2'); font-display: swap; }"
    #expect(
        BoardEdit.addFontFace("<style>h1{}</style><p>", family: "Grotesk", file: "G.woff2") == "<style>h1{}" + face
            + "\n</style><p>")
    #expect(
        BoardEdit.addFontFace("<head></head>", family: "Grotesk", file: "G.woff2")
            == "<head><style>\(face)</style>\n</head>")
    #expect(BoardEdit.addFontFace("<p>a</p>", family: "Grotesk", file: "G.woff2") == "<style>\(face)</style>\n<p>a</p>")
    #expect(BoardEdit.addFontFace("<p>", family: "x'); }", file: "G.woff2") == nil)
}

/// A 16:9 stage made 9:16: fitted, its content is framed at its design size and scaled into the middle; filled, it
/// covers the stage, cropped at the sides; changed again, the same frame is scaled from its design size; as it is,
/// nothing moves.
@Test func aStageChangesShapeByFittingOrFilling() {
    let page = #"<body data-width="1920" data-height="1080"><h1>Hi</h1></body>"#
    let fit = StageReframe.fit.apply(page, old: (1920, 1080), width: 1080, height: 1920)
    #expect(
        fit.contains(
            #"data-kelp-frame="1920x1080" style="position: absolute; left: 0px; top: 656.25px; width: 1920px; height: 1080px; transform: scale(0.5625)"#
        ))
    #expect(fit.contains("<h1>Hi</h1></div>"))
    let fill = StageReframe.fill.apply(fit, old: (1080, 1920), width: 1080, height: 1920)
    #expect(
        fill.contains("left: -1166.67px; top: 0px; width: 1920px")
            && fill.components(separatedBy: "data-kelp-frame").count == 2)
    #expect(StageReframe.none.apply(page, old: (1920, 1080), width: 1080, height: 1920) == page)
}

/// A style for every element of a class: each with the class among others gets it, one with a longer class name that
/// starts the same doesn't, and a value that could end the attribute is refused.
@Test func everyElementOfAClassTakesAStyle() throws {
    let page = #"<div class="card big">A</div><div class="cards">B</div><p class="card" style="color: red">C</p>"#
    let (out, n) = try #require(BoardEdit.setStyle(page, className: "card", property: "border-radius", value: "12px"))
    #expect(n == 2)
    #expect(
        out
            == #"<div class="card big" style="border-radius: 12px">A</div><div class="cards">B</div><p class="card" style="color: red; border-radius: 12px">C</p>"#
    )
    #expect(BoardEdit.setStyle(page, className: "card", property: "color", value: "red\"") == nil)
}

/// Keeping a variation takes the board's variations off canvas.json and leaves everything else the agent wrote there.
@Test func keptVariationsLeaveTheCanvas() throws {
    let json =
        #"{"boards": [{"file": "boards/A.html", "w": 900}, {"file": "boards/A-b.html", "variant": "boards/A.html"}, {"file": "boards/B.html", "note": "mine"}], "pages": 2}"#
    let out = try ArtifactCanvas.editBoards(json) { $0.filter { ($0["variant"] as? String) != "boards/A.html" } }
    #expect(ArtifactCanvas.read(out)?.boards.map(\.file) == ["boards/A.html", "boards/B.html"])
    #expect(out.contains(#""note" : "mine""#) && out.contains(#""pages" : 2"#))
    #expect(throws: (any Error).self) { try ArtifactCanvas.editBoards("{", { $0 }) }
}
