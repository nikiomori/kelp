import Core
import Testing

@testable import BuiltinFiles

private func hunk(_ newStart: Int, _ s: String) -> Hunk {
    let lines = s.map { c -> DiffLine in DiffLine(kind: c == "+" ? .add : c == "-" ? .del : .context, text: "") }
    return Hunk(header: "", oldStart: 1, newStart: newStart, lines: lines)
}

/// Runs of lines read as added, changed and removed, several to a hunk; a wholly removed file marks the top.
@Test func linesReadAsAddedChangedAndRemoved() {
    let cases: [(hunks: [Hunk], changes: [LineChange])] = [
        ([hunk(1, " + ")], [LineChange(kind: .added, line: 1, count: 1, hunk: 0)]),
        ([hunk(10, " --+ ")], [LineChange(kind: .changed, line: 10, count: 1, hunk: 0)]),
        ([hunk(1, " - ")], [LineChange(kind: .removed, line: 1, count: 0, hunk: 0)]),
        (
            [hunk(1, "+ - ++"), hunk(20, "-")],
            [
                LineChange(kind: .added, line: 0, count: 1, hunk: 0),
                LineChange(kind: .removed, line: 2, count: 0, hunk: 0),
                LineChange(kind: .added, line: 3, count: 2, hunk: 0),
                LineChange(kind: .removed, line: 19, count: 0, hunk: 1)
            ]
        ),
        ([hunk(0, "---")], [LineChange(kind: .removed, line: 0, count: 0, hunk: 0)])
    ]
    for (number, c) in cases.enumerated() {
        #expect(LineChange.of(c.hunks) == c.changes, "case \(number)")
    }
}
