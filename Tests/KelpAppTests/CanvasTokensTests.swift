import Foundation
import JavaScriptCore
import Testing

@testable import BuiltinFiles

/// Check's findings are read back for their fix: a value that isn't a token (the board, what, the value, the element,
/// the nearest token) and what VoiceOver would miss (the board, what, the element), from a light or a dark board.
@MainActor @Test func aFindingIsReadForItsFix() throws {
    let tokens = CanvasTokens.finding, access = CanvasAccess.finding
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
        (access, "a.html: 2 buttons, links, fields or headings without a data-id", [])
    ]
    for (source, line, parts) in cases {
        let pattern = try NSRegularExpression(pattern: source)
        let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        let got = m.map { m in (1..<m.numberOfRanges).map { (line as NSString).substring(with: m.range(at: $0)) } }
        #expect((got ?? []) == parts, "\(line)")
    }
}

/// Edit's Link, Picture and Arrange and the token fixes are scripts the page runs whole: a mistake in one (a pattern
/// escaped once too few) stops all of it. They run here against a bare stand-in for the page.
@MainActor @Test func editsExtraScriptsRun() throws {
    let context = try #require(JSContext())
    context.evaluateScript(
        """
        var window = { kelpCanvas: { frames: [] }, kelpProps: {} };
        var document = { createElement: () => ({ style: {} }) };
        """)
    context.evaluateScript(CanvasEditMore.source(labels: [:]))
    #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
    #expect(context.evaluateScript("typeof window.kelpIssueFix")?.toString() == "function")
    #expect(context.evaluateScript("window.kelpProps.more.length")?.toInt32() == 3)
}
