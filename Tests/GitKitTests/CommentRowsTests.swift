import Testing
import Core
import WorkbenchKit

private func line(_ k: DiffLine.Kind, _ t: String, o: Int? = nil, n: Int? = nil) -> DiffLine { DiffLine(kind: k, text: t, oldLine: o, newLine: n) }

@Test func aCommentOnADeletedLineShowsOnceNotUnderTheAddedLineWithTheSameNumber() {
    let gone = FileDiff(path: "f.swift", header: "", hunks: [
        Hunk(header: "@@ -5,2 +5 @@", oldStart: 5, newStart: 5, lines: [line(.del, "old five", o: 5), line(.del, "old six", o: 6), line(.add, "new five", n: 5)])
    ], binary: false)
    let c = DiffComment(worktreeId: "w", file: "f.swift", startLine: 6, endLine: 6, quote: "", text: "why?")
    for side in [false, true] {
        let rows = DiffRows.reviewRows([gone], comments: [c], sideBySide: side, hideFileRows: true)
        #expect(rows.filter { if case .comment = $0 { true } else { false } }.count == 1, "side by side: \(side)")   // the new file has no line 6, so the deleted line 6 takes it
    }
    let on5 = DiffComment(worktreeId: "w", file: "f.swift", startLine: 5, endLine: 5, quote: "", text: "hm")
    let rows = DiffRows.reviewRows([gone], comments: [on5], sideBySide: false, hideFileRows: true)
    #expect(rows.filter { if case .comment = $0 { true } else { false } }.count == 1)   // line 5 exists in both files: under the added one only
}

/// A comment on a removed line stays under that removed line, inline and side by side, even where the new file has a
/// line with its number; a comment on the new file's line doesn't land on the removed one.
@Test func aCommentOnTheOldSideSitsUnderTheRemovedLine() {
    let gone = FileDiff(path: "f.swift", header: "", hunks: [
        Hunk(header: "@@ -5,2 +5 @@", oldStart: 5, newStart: 5, lines: [line(.del, "old five", o: 5), line(.del, "old six", o: 6), line(.add, "new five", n: 5)])
    ], binary: false)
    let old5 = DiffComment(worktreeId: "w", file: "f.swift", startLine: 5, endLine: 5, quote: "", text: "old", side: "old")
    let new5 = DiffComment(worktreeId: "w", file: "f.swift", startLine: 5, endLine: 5, quote: "", text: "new")
    for side in [false, true] {
        let rows = DiffRows.reviewRows([gone], comments: [old5, new5], sideBySide: side, hideFileRows: true)
        #expect(rows.filter { if case .comment = $0 { true } else { false } }.count == 2, "side by side: \(side)")
        if !side, let at = rows.firstIndex(where: { if case .comment(let c) = $0 { c.id == old5.id } else { false } }),
           case .diff(.line(_, let l)) = rows[at - 1] {
            #expect(l.kind == .del && l.oldLine == 5)
        } else if !side { Issue.record("the old side's comment isn't under the removed line") }
    }
}

/// A gap names the function git found above the next change, and an opened one shows its lines in its place.
@Test func aGapNamesItsFunctionAndOpensInPlace() {
    let h1 = Hunk(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [line(.add, "a", n: 1)])
    let h2 = Hunk(header: "@@ -5 +5 @@ func load() {", oldStart: 5, newStart: 5, lines: [line(.add, "e", n: 5)])
    let f = FileDiff(path: "f.swift", header: "", hunks: [h1, h2], binary: false)
    #expect(DiffRows.build([f], sideBySide: false).contains(.gap(file: 0, from: 2, lines: 3, context: "func load() {")))
    let shown = (2...4).map { DiffLine(kind: .context, text: "x\($0)", oldLine: $0, newLine: $0) }
    let open = DiffRows.build([f], sideBySide: true, opened: [DiffRows.gapKey("f.swift", 2): shown])
    #expect(!open.contains { if case .gap = $0 { true } else { false } })
    #expect(open.contains(.pair(file: 0, left: shown[1], right: shown[1])))
    #expect(DiffRows.context("@@ -1 +1 @@") == "")
}
