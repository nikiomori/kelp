import Core
import Foundation
import Testing

@testable import BuiltinGit

@Test func sideBySidePairingAndGaps() {
    func l(_ k: DiffLine.Kind, _ t: String, o: Int? = nil, n: Int? = nil) -> DiffLine {
        DiffLine(kind: k, text: t, oldLine: o, newLine: n)
    }
    let h1 = Hunk(
        header: "@@ -1,3 +1,3 @@", oldStart: 1, newStart: 1,
        lines: [l(.context, "a", o: 1, n: 1), l(.del, "b", o: 2), l(.del, "c", o: 3), l(.add, "B", n: 2)])
    let p = DiffRows.pairs(h1.lines)
    #expect(p.count == 3)
    #expect(p[1].0?.text == "b" && p[1].1?.text == "B")
    #expect(p[2].0?.text == "c" && p[2].1 == nil)
    let h2 = Hunk(header: "@@ -20 +20 @@", oldStart: 20, newStart: 20, lines: [l(.add, "z", n: 20)])
    let rows = DiffRows.build([FileDiff(path: "f", header: "", hunks: [h1, h2], binary: false)], sideBySide: false)
    #expect(rows.contains(.gap(file: 0, from: 3, lines: 17, context: "")))
}

@Test func changedRangesKeepOnlyWhatDiffers() {
    func r(_ a: String, _ b: String) -> (NSRange, NSRange) { DiffRows.changedRanges(a, b) }
    #expect(r("let x = 1", "let x = 2") == (NSRange(location: 8, length: 1), NSRange(location: 8, length: 1)))
    #expect(r("foo(a)", "foo(a, b)") == (NSRange(location: 5, length: 0), NSRange(location: 5, length: 3)))   // an insertion has an empty old side
    #expect(r("same", "same") == (NSRange(location: 4, length: 0), NSRange(location: 4, length: 0)))
    #expect(r("abc", "xyz") == (NSRange(location: 0, length: 3), NSRange(location: 0, length: 3)))
    #expect(r("aXa", "aa") == (NSRange(location: 1, length: 1), NSRange(location: 1, length: 0)))   // the common end can't overlap the common start
}

private func line(_ k: DiffLine.Kind, _ t: String, o: Int? = nil, n: Int? = nil) -> DiffLine {
    DiffLine(kind: k, text: t, oldLine: o, newLine: n)
}
private let sample = FileDiff(
    path: "f.swift", header: "",
    hunks: [
        Hunk(
            header: "@@ -1,2 +1,2 @@", oldStart: 1, newStart: 1,
            lines: [line(.context, "a", o: 1, n: 1), line(.del, "x = 1", o: 2), line(.add, "x = 2", n: 2)])
    ], binary: false)

@Test func changedWordsAreKeyedByFileAndLine() {
    let w = DiffRows.changedWords([sample])
    #expect(w["0:d:2"] == NSRange(location: 4, length: 1) && w["0:a:2"] == NSRange(location: 4, length: 1))
    #expect(w.count == 2)   // the context line has no counterpart
}

@Test func commentsSitUnderTheirLastLineAndResolvedOnesLeave() {
    func c(_ line: Int, _ state: DiffComment.State, _ file: String = "f.swift") -> DiffComment {
        DiffComment(
            worktreeId: "w", file: file, startLine: line, endLine: line, quote: "", text: "t\(line)", state: state)
    }
    let open = c(2, .open), sent = c(2, .sent), done = c(2, .resolved), other = c(2, .open, "g.swift")
    let rows = DiffRows.reviewRows(
        [sample], comments: [open, sent, done, other], sideBySide: false, hideFileRows: false)
    let comments = rows.compactMap { if case .comment(let c) = $0 { c.id } else { nil } }
    #expect(comments == [open.id, sent.id])   // not the resolved one, not another file's
    let at = rows.firstIndex { if case .comment = $0 { true } else { false } } ?? 0
    if case .diff(.line(_, let l)) = rows[at - 1] {
        #expect(l.newLine == 2 && l.kind == .add)
    } else {
        Issue.record("the comment isn't under its line")
    }
}

@Test func oneFileModeHidesTheFileRow() {
    let withFile = DiffRows.reviewRows([sample], comments: [], sideBySide: true, hideFileRows: false)
    let without = DiffRows.reviewRows([sample], comments: [], sideBySide: true, hideFileRows: true)
    #expect(withFile.count == without.count + 1)
    #expect(!without.contains { if case .diff(.file) = $0 { true } else { false } })
}
