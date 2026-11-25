// Finding text in what a session printed, as ⌘P's lines of output show it.
import Testing

@testable import Daemon

/// Matches as Ghostty's find does, and cuts a long line to the part around the match.
@Test(arguments: [
    ("Make", "a\nmake it\r\nMAKE IT AGAIN  \nb", "MAKE IT AGAIN", 2),
    ("ошибка", "Ошибка\nошибка сети", "ошибка сети", 1),   // only ASCII letters fold, as in Ghostty
    (
        "needle", String(repeating: "x", count: 80) + " needle end",
        "…" + String(repeating: "x", count: 19) + " needle end", 1
    ),
    ("redraw", "50% redraw\r100% redraw", "100% redraw", 2)
])
func outputSearchFindsTheNewestLine(query: String, text: String, line: String, count: Int) {
    let found = OutputSearch.newest(query, in: text)
    #expect(found?.line == line && found?.count == count)
}

@Test func outputSearchFindsNothingInLinesWithoutTheText() {
    #expect(OutputSearch.newest("migrate", in: "a\nb") == nil)
    #expect(OutputSearch.newest("", in: "a") == nil)
}
