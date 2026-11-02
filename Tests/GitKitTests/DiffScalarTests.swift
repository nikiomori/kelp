import Foundation
import Testing
import Core
@testable import GitKit

/// A line that starts with a combining mark: with its "+" it's one Character, and it used to fall out of the hunk.
@Test func aLineStartingWithACombiningMarkStaysInItsHunk() throws {
    let d = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+\u{0301}x\n"
    let lines = try #require(Git.parseDiff(d).first?.hunks.first?.lines)
    #expect(lines.count == 1 && lines[0].kind == .add && lines[0].text == "\u{0301}x")
}
