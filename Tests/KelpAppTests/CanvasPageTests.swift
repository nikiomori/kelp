import Core
import Foundation
import TestSupport
import Testing

@testable import BuiltinFiles

/// A project with a design system and a canvas of two boards, one of them missing, in a temporary folder.
private func demo() throws -> (root: URL, folder: URL) {
    let root = tmp().appendingPathComponent("canvas-\(UUID().uuidString)")
    let folder = root.appendingPathComponent(".kelp/artifacts/home")
    let system = DesignSystem.dir(root: root.path)
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("boards"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
    try ##"{"color": {"bg": {"light": "#fafafa", "dark": "#111111"}, "accent": "#1f7a5a"}}"##
        .write(to: system.appendingPathComponent("tokens.json"), atomically: true, encoding: .utf8)
    try ".button { color: var(--accent); }".write(
        to: system.appendingPathComponent("kit.css"), atomically: true, encoding: .utf8)
    try "<!-- tweak --gap: 8px (8px, 16px) -->\n<h1 data-id=\"t\" style=\"color: #333\">Hi & \"you\"</h1>".write(
        to: folder.appendingPathComponent("boards/A.html"), atomically: true, encoding: .utf8)
    return (root, folder)
}

@Test func aCanvasPageDrawsEachBoardInLightAndDarkFromTheSystem() throws {
    let (root, folder) = try demo()
    defer { try? FileManager.default.removeItem(at: root) }
    let json =
        #"{"boards": [{"file": "boards/A.html", "row": "A. One", "w": 390, "h": 844, "notes": "Say \"hi\""}, "#
        + #"{"file": "boards/B.html"}]}"#
    let page = CanvasPage.build(
        CanvasSnapshot.live(json: json, folder: folder), folder: folder, root: root.path, view: .init(themes: .both))
    #expect(page.html.components(separatedBy: "<iframe").count - 1 == 2, "A in light and dark; B is missing")
    #expect(page.html.contains("data-theme=\"dark\"") && page.html.contains("--bg: #111111;"))
    #expect(page.html.contains("--gap: 8px;"), "the board's tweaks are set on its page")
    #expect(page.html.contains("&lt;h1 data-id=&quot;t&quot;"), "the fragment is escaped into srcdoc")
    #expect(page.html.contains("<h2>A. One</h2>") && page.html.contains("390 × 844"))
    #expect(page.html.contains(#"data-notes="Say &quot;hi&quot;""#), "a slide's notes, for Present with Notes")
    #expect(page.issues.contains("boards/B.html: no such file"))
    #expect(page.issues.contains("boards/A.html: 1 colours typed in; use the tokens (var(--name))"))
    let light = CanvasPage.build(
        CanvasSnapshot.live(json: json, folder: folder), folder: folder, root: root.path, view: .init(themes: .light))
    #expect(light.html.components(separatedBy: "<iframe").count - 1 == 1)
}

@Test func aCanvasThatDoesntReadSaysSo() throws {
    let (root, folder) = try demo()
    defer { try? FileManager.default.removeItem(at: root) }
    let page = CanvasPage.build(
        CanvasSnapshot.live(json: "{", folder: folder), folder: folder, root: root.path, view: .init(themes: .both))
    #expect(page.issues.first?.hasPrefix("canvas.json: ") == true && page.html.contains("data-kelp=\"fixCanvas\""))
    #expect(CanvasPage.lint("<html><body><script>x()</script>", board: "b", hasSystem: false).count == 2)
    let figures = #"<b data-value data-source="gh run list, today">42</b> <b class="n" data-value>7</b>"#
    #expect(
        CanvasPage.lint(figures, board: "b", hasSystem: false)
            == ["b: 1 figures without data-source (where each came from, and when)"])
}

@Test func anOlderVersionOfACanvasIsDrawnWithItsOwnBoards() throws {
    let (root, folder) = try demo()
    defer { try? FileManager.default.removeItem(at: root) }
    let json = #"{"boards": [{"file": "boards/A.html", "w": 390}]}"#
    let then = CanvasSnapshot(canvas: json, boards: ["boards/A.html": "<p>Then</p>"])
    let kept = try #require(then.data.map { String(decoding: $0, as: UTF8.self) })
    let page = CanvasPage.build(
        try #require(CanvasSnapshot.read(kept)), folder: folder, root: root.path, view: .init(themes: .light))
    #expect(page.html.contains("&lt;p&gt;Then&lt;/p&gt;") && !page.html.contains("Hi &amp;amp;"))
    #expect(CanvasSnapshot.live(json: json, folder: folder).boards["boards/A.html"]?.contains("Hi & ") == true)
}

/// A mark to check brings its board as it was sent, in each theme shown, for Before; others bring nothing.
@Test func aMarkToCheckBringsItsBoardAsItWasSent() throws {
    let (root, folder) = try demo()
    defer { try? FileManager.default.removeItem(at: root) }
    let json = #"{"boards": [{"file": "boards/A.html", "w": 390}]}"#
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("versions"), withIntermediateDirectories: true)
    try #require(CanvasSnapshot(canvas: json, boards: ["boards/A.html": "<p>Then</p>"]).data).write(
        to: folder.appendingPathComponent("versions/1.json"))
    let round = ArtifactMark.Round(note: "bigger", at: 0, before: 1, after: 2, outcome: .changed)
    for (state, drawn) in [(ArtifactMark.State.check, ["boards/A.html@1@dark", "boards/A.html@1@light"]), (.done, [])] {
        let marks = ArtifactMarks(marks: [
            ArtifactMark(id: 1, board: "boards/A.html", target: "[data-id=t]", state: state, rounds: [round])
        ])
        try marks.encoded().write(to: folder.appendingPathComponent("notes.json"))
        let page = CanvasPage.build(
            CanvasSnapshot.live(json: json, folder: folder), folder: folder, root: root.path, view: .init(themes: .both)
        )
        #expect(page.before.keys.sorted() == drawn && page.marks.marks == marks.marks)
        #expect(page.before.values.allSatisfy { $0.contains("<p>Then</p>") && $0.contains("--bg") })
    }
}

@Test func whileItsAgentWritesABoardNotThereYetIsAFrameOfItsSize() throws {
    let (root, folder) = try demo()
    defer { try? FileManager.default.removeItem(at: root) }
    let json = #"{"boards": [{"file": "boards/A.html", "w": 390}, {"file": "boards/B.html", "w": 600, "h": 400}]}"#
    let live = CanvasSnapshot.live(json: json, folder: folder)
    let writing = CanvasPage.build(live, folder: folder, root: root.path, view: .init(themes: .light, writer: "Codex"))
    #expect(writing.html.contains("kelp-skel") && writing.html.contains("width: 600px; height: 400px"))
    #expect(!writing.issues.contains("boards/B.html: no such file") && writing.html.contains("kelp-ring"))
    let empty = CanvasPage.build(
        CanvasSnapshot.live(json: ArtifactCanvas.empty, folder: folder), folder: folder, root: root.path,
        view: .init(themes: .light, writer: "Codex"))
    #expect(empty.html.contains("Codex is writing the first one"))
}

/// A motion page is drawn as a canvas of one board, its stage, at the size its body says, so Mark and Edit work on
/// it; a stage that says no size is 1920 × 1080.
@Test func aMotionPageIsAStageBoardAtItsOwnSize() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("motion-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let built = MotionPage.build(
        #"<html><body data-height="1920" data-width="1080"><h1 data-id="t">Hi</h1></body></html>"#,
        folder: folder, root: folder.path)
    #expect(built.html.contains(#"data-board="motion.html""#))
    #expect(built.html.contains(#"data-w="1080" data-h="1920""#))
    #expect(built.html.contains("kelp-motion-page"))
    #expect(MotionPage.size("<body>") == (1920, 1080))
}

/// The check's bar says what was asked of the mark shown and what the agent answered; with nothing asked, whose turn
/// ended.
@MainActor @Test func theCheckBarSaysWhatWasAskedAndAnswered() {
    let bar = MarkReviewBar { _ in }
    bar.show(count: 2, at: 0, before: (false, false), who: "Claude", said: ("bigger", "Made it 40px"))
    #expect(bar.label.stringValue == "“bigger” · Made it 40px" && !bar.bar.isHidden)
    bar.show(count: 2, at: 1, before: (false, false), who: "Claude", said: ("bigger", ""))
    #expect(bar.label.stringValue == "“bigger” · Claude didn’t answer it")
    bar.show(count: 1, at: 0, before: (false, false), who: nil, said: ("", ""))
    #expect(bar.label.stringValue == "The agent finished its turn")
}

/// After a turn the agent hears what doesn't fit a narrower width only while a board is shown that narrow.
@Test func narrowFindingsGoToTheAgentOnlyWhenShownNarrow() {
    let found = ["boards/A.html @390: content is 420px wide, the board 390", "boards/A.html: text is cut off in h1"]
    #expect(MarkdownTab.told(found, narrow: false) == [found[1]])
    #expect(MarkdownTab.told(found, narrow: true) == found)
}

/// A doc's links to files that aren't there are found from its Markdown; a link to the web, to a heading, to a file
/// that is there, and a picture (found where it's drawn) are not.
@Test func aDocsLinksToMissingFilesAreFound() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-doc-links-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "x".write(to: folder.appendingPathComponent("here.md"), atomically: true, encoding: .utf8)
    let md = """
        [there](here.md#part) [gone](gone.md) [web](https://example.com) [top](#plan) ![pic](nope.png)
        [spaced](<my%20notes.md> "title")
        """
    #expect(
        PageCheck.missingFiles(md, folder: folder)
            == ["a link to gone.md: no such file", "a link to my%20notes.md: no such file"])
}

/// Commands a dashboard may run are allowed for its page in its project: a cloned repository with a page at the same
/// place doesn't inherit them, and a link to the page is the page.
@Test func aDashboardsAllowedCommandsStayInItsProject() throws {
    let base = tmp().appendingPathComponent("sources-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let page = ".kelp/artifacts/stats/canvas.json"
    let mine = base.appendingPathComponent("mine/" + page), theirs = base.appendingPathComponent("clone/" + page)
    for url in [mine, theirs] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }
    let link = base.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("mine"))
    let key = { (page: URL) in MarkdownTab.sourcesKey("artifacts.sources:", page.path) }
    #expect(key(mine) != key(theirs))
    #expect(key(link.appendingPathComponent(page)) == key(mine))
}
