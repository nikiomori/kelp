import AppKit
import DesignKit
import Foundation
import Testing

@testable import BuiltinFiles
@testable import EditorKit

/// The status bar's problem count is two parts, each with its own symbol and its own colour: warnings stay orange
/// beside red errors, and a count of none is left out.
@MainActor @Test func theProblemCountDrawsErrorsAndWarningsApart() {
    let sign = "\u{FFFC}"   // a symbol's attachment
    let rows: [(errors: Int, warnings: Int, parts: [(text: String, color: NSColor)])] = [
        (2, 3, [(sign + "2", .textRed), (sign + "3", .textOrange)]),
        (0, 3, [(sign + "3", .textOrange)]),
        (1, 0, [(sign + "1", .textRed)])
    ]
    for row in rows {
        let count = EditorStatusBar.problemCount(errors: row.errors, warnings: row.warnings)
        var parts: [(text: String, color: NSColor?)] = []
        count.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: count.length)) { color, range, _ in
            parts.append(((count.string as NSString).substring(with: range), color as? NSColor))
        }
        #expect(parts.map(\.text) == row.parts.map(\.text), "\(row.errors) errors, \(row.warnings) warnings")
        #expect(zip(parts, row.parts).allSatisfy { $0.color === $1.color })
    }
}

/// On the scroller, a git change and a problem on the same line are told apart by their form, not only by colour.
@MainActor @Test func theScrollerDrawsChangesAndProblemsInTheirOwnForms() throws {
    _ = NSApplication.shared
    let e = CodeEditor(text: (1...100).map { "line \($0)\n" }.joined(), url: URL(fileURLWithPath: "/tmp/forms.txt"))
    e.problems = [.init(line: 50, column: 0, endLine: 50, endColumn: 2, isError: false, message: "x")]
    e.changeMarks = [.init(kind: .changed, line: 50, count: 1, hunk: 0)]
    let marks = try #require((e.scroll as? EditorScrollView)?.marks)
    let onLine = marks.ticks.filter { $0.line == 50 }
    #expect(Set(onLine.map(\.form)) == [.change, .problem])
    #expect(onLine.allSatisfy { $0.color === NSColor.textOrange })
}
