import Core
import Testing
import WorkbenchKit

private func hunk(_ newStart: Int, _ s: String) -> Hunk {
    let lines = s.map { c -> DiffLine in DiffLine(kind: c == "+" ? .add : c == "-" ? .del : .context, text: "") }
    return Hunk(header: "", oldStart: 1, newStart: newStart, lines: lines)
}

@Test func runsOfLinesReadAsAddedChangedAndRemoved() {
    #expect(LineChange.of([hunk(1, " + ")]) == [LineChange(kind: .added, line: 1, count: 1, hunk: 0)])
    #expect(LineChange.of([hunk(10, " --+ ")]) == [LineChange(kind: .changed, line: 10, count: 1, hunk: 0)])
    #expect(LineChange.of([hunk(1, " - ")]) == [LineChange(kind: .removed, line: 1, count: 0, hunk: 0)])
}

@Test func aHunkCanHoldSeveralChanges() {
    #expect(
        LineChange.of([hunk(1, "+ - ++"), hunk(20, "-")]) == [
            LineChange(kind: .added, line: 0, count: 1, hunk: 0),
            LineChange(kind: .removed, line: 2, count: 0, hunk: 0),
            LineChange(kind: .added, line: 3, count: 2, hunk: 0),
            LineChange(kind: .removed, line: 19, count: 0, hunk: 1)
        ])
}

@Test func aWhollyRemovedFileMarksTheTop() {
    #expect(LineChange.of([hunk(0, "---")]) == [LineChange(kind: .removed, line: 0, count: 0, hunk: 0)])
}
