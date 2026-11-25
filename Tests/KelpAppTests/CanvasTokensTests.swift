import Foundation
import JavaScriptCore
import Testing

@testable import BuiltinFiles

/// Check's findings are read back for their fix: a value that isn't a token (the board, what, the value, the element,
/// the nearest token), what VoiceOver would miss (the board, what, the element) and a dead end in the flow (the board,
/// the element), from a light or a dark board.
@MainActor @Test func aFindingIsReadForItsFix() throws {
    let tokens = CanvasTokens.finding, access = CanvasAccess.finding, dead = CanvasLinks.deadEnd
    let cases: [(String, String, [String])] = [
        (
            tokens, "boards/A.html: colour #1f7a5a in [data-id=cta] is not a token (nearest: accent #2f7d5b)",
            ["boards/A.html", "colour", "#1f7a5a", "cta", "accent"]
        ),
        (
            tokens, "b.html (dark): size 34px in [data-id=title] is not a token (nearest: title 36px)",
            ["b.html", "size", "34px", "title", "title"]
        ),
        (
            tokens, "a.html: radius 10px in [data-id=hero] is not a token (nearest: l 12px)",
            ["a.html", "radius", "10px", "hero", "l"]
        ),
        (tokens, "a.html: font Georgia in [data-id=t] is not a token (body)", []),
        (
            access, "a.html: picture without a description (alt) in [data-id=hero]",
            ["a.html", "picture without a description", "hero"]
        ),
        (access, "a.html: h4 after h1 in [data-id=small]: skips a level", ["a.html", "h4 after h1", "small"]),
        (
            access, "a.html: reading order differs from what is seen in [data-id=rev] (order or a reversed row)",
            ["a.html", "reading order differs", "rev"]
        ),
        (access, "a.html: 2 buttons, links, fields or headings without a data-id", []),
        (dead, "boards/B.html: «Skip» in [data-id=skip] goes nowhere", ["boards/B.html", "skip"]),
        (dead, "b.html: «Skip» goes nowhere", [])
    ]
    for (source, line, parts) in cases {
        let pattern = try NSRegularExpression(pattern: source)
        let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        let got = m.map { m in (1..<m.numberOfRanges).map { (line as NSString).substring(with: m.range(at: $0)) } }
        #expect((got ?? []) == parts, "\(line)")
    }
}

/// Edit's Link, Picture and Arrange, the fixes under Check's findings and the boards' widths are scripts the page runs
/// whole: a mistake in one (a pattern escaped once too few) stops all of it. They run here against a bare stand-in.
@MainActor @Test func editsExtraScriptsRun() throws {
    let context = try #require(JSContext())
    context.evaluateScript(
        """
        const node = () => ({ style: {}, dataset: {}, classList: { toggle() {} }, children: [], append() {} });
        var window = {
          kelpCanvas: { frames: [], el: node, sheet: { addEventListener() {} }, claims: [] }, kelpProps: {} };
        var document = { createElement: node, body: { matches: () => false }, querySelector: () => null };
        var setTimeout = () => 0, clearTimeout = () => {};
        """)
    context.evaluateScript(CanvasEditMore.source(labels: [:]))
    #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
    #expect(context.evaluateScript("typeof window.kelpIssueFix")?.toString() == "function")
    #expect(context.evaluateScript("window.kelpProps.more.length")?.toInt32() == 7)   // + lines and letters, edges
    #expect(context.evaluateScript("typeof window.kelpSetRows")?.toString() == "function")
    #expect(context.evaluateScript("window.kelpCheckMore.length")?.toInt32() == 2)
    #expect(context.evaluateScript("typeof window.kelpChartNumbers")?.toString() == "function")
}

/// A page started from a file, or made from another page, is a fixed request to the agent: what to make, from what,
/// how pages of that kind are made here, and the decisions already made.
@MainActor @Test func aPageFromAFileOrAnotherPageIsAskedForPlainly() {
    #expect(ArtifactStart.kinds["pptx"] == .slides && ArtifactStart.kinds["xlsx"] == .dashboard)
    let fromFile = ArtifactStart.brief(
        from: ".kelp/artifacts/q3/Q3.pptx", page: ".kelp/artifacts/q3/slides.md", kind: .slides)
    #expect(fromFile.contains("from .kelp/artifacts/q3/Q3.pptx") && fromFile.contains("kelp artifact guide slides"))
    let turned = ArtifactStart.brief(
        turning: ".kelp/artifacts/home/canvas.json", into: ".kelp/artifacts/home-2/motion.html", kind: .motion,
        decided: ["#1 bigger"])
    #expect(turned.hasPrefix("Make .kelp/artifacts/home-2/motion.html from .kelp/artifacts/home/canvas.json"))
    #expect(turned.hasSuffix("Decisions already made on it: #1 bigger."))
    let like = ArtifactStart.brief(
        like: ".kelp/artifacts/q3/canvas.json", page: ".kelp/artifacts/q4/canvas.json", kind: .design)
    #expect(
        like.contains("copy its files into .kelp/artifacts/q4 first") && like.hasSuffix("to: "), "the user says what")
    #expect(ArtifactStart.brand.contains("svg") && ArtifactStart.kinds["svg"] == nil, "a logo makes a design system")

}

/// Publishing goes through the page's agent, which writes the link where ⋯ finds it; comments come back as marks on
/// a canvas (an element to put them on) and as suggestions on a doc.
@MainActor @Test func aPageIsPublishedAndItsCommentsBroughtInByItsAgent() {
    let page = ".kelp/artifacts/home/canvas.json"
    #expect(
        MarkdownTab.publish(page, link: ".kelp/artifacts/home/published.txt").contains(
            "into .kelp/artifacts/home/published.txt"))
    let link = "https://claude.ai/artifact/abc"
    #expect(MarkdownTab.comments(page, link: link, canvas: true).contains("kelp artifact ask home <data-id"))
    #expect(
        MarkdownTab.comments(".kelp/artifacts/plan/doc.md", link: link, canvas: false).contains(
            "kelp artifact suggest plan"))
    #expect(MarkdownTab.republish(page, link: link).contains("the same link"))
}

/// A rehearsal tells the agent the length aimed at and taken, each slide's time, and which ran long (over half again
/// their share), the longest first; the speaker's window that times them parses.
@MainActor @Test func aRehearsalSaysWhatRanLong() throws {
    let times: [Double] = [20, 190, 160, 70]
    #expect(Rehearsal.long(times, target: 240) == [1, 2])
    #expect(
        Rehearsal.message(page: "deck.md", times: times, target: 240) == """
            Rehearsed deck.md: aimed at 4:00, took 7:20.
            Per slide: 1 0:20, 2 3:10, 3 2:40, 4 1:10.
            Longest: 2 (3:10), 3 (2:40); cut each toward 1:00, keeping what it says.
            """)
    #expect(!Rehearsal.message(page: "deck.md", times: [50, 50], target: 600).contains("Longest"))
    let context = try #require(JSContext())
    let js = Presenter.script(labels: [:], target: 600)
    let literal = String(data: try JSONSerialization.data(withJSONObject: [js]), encoding: .utf8) ?? "[]"
    context.evaluateScript("new Function(\(literal)[0])")
    #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
}
