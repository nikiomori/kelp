import Foundation
import JavaScriptCore
import Testing

@testable import BuiltinFiles

/// Check's findings about a value that isn't a token are read back for their fix: the board, what, the value, the
/// element and the nearest token, from a light or a dark board.
@MainActor @Test func aFindingAboutATokenIsReadForItsFix() throws {
    let pattern = try NSRegularExpression(pattern: CanvasTokens.finding)
    let cases: [(String, [String])] = [
        (
            "boards/A.html: colour #1f7a5a in [data-id=cta] is not a token (nearest: accent #2f7d5b)",
            ["boards/A.html", "colour", "#1f7a5a", "cta", "accent"]
        ),
        (
            "b.html (dark): size 34px in [data-id=title] is not a token (nearest: title 36px)",
            ["b.html", "size", "34px", "title", "title"]
        ),
        (
            "a.html: radius 10px in [data-id=hero] is not a token (nearest: l 12px)",
            ["a.html", "radius", "10px", "hero", "l"]
        ),
        ("a.html: font Georgia in [data-id=t] is not a token (body)", [])
    ]
    for (line, parts) in cases {
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
