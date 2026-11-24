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
        var window = { kelpCanvas: { frames: [], el: node }, kelpProps: {} };
        var document = { createElement: node, body: { matches: () => false }, querySelector: () => null };
        """)
    context.evaluateScript(CanvasEditMore.source(labels: [:]))
    #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
    #expect(context.evaluateScript("typeof window.kelpIssueFix")?.toString() == "function")
    #expect(context.evaluateScript("window.kelpProps.more.length")?.toInt32() == 4)
    #expect(context.evaluateScript("window.kelpCheckMore.length")?.toInt32() == 2)
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
}
