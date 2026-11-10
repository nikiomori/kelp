import Core
import Testing

@testable import BuiltinGit

private func file(_ path: String, _ text: String) -> FileDiff {
    FileDiff(
        path: path, header: "",
        hunks: [
            Hunk(
                header: "@@ -1 +1 @@", oldStart: 1, newStart: 1,
                lines: [DiffLine(kind: .add, text: text, newLine: 1)])
        ], binary: false)
}

/// A file marked as read stays read while its diff is the one marked; an agent's change makes it unread by itself,
/// and marks of files another source shows stay, until there are too many.
@Test func aViewedFileComesBackWhenItsDiffChanges() {
    let a = file("a.swift", "one"), b = file("b.swift", "two")
    #expect(ViewedFiles.print(a) == ViewedFiles.print(file("a.swift", "one")))   // the same on every run
    var marks = ViewedFiles.read(ViewedFiles.marking(a, true, in: [:], diffs: [a, b]))
    #expect(ViewedFiles.viewed(a, in: marks) && !ViewedFiles.viewed(b, in: marks))
    #expect(!ViewedFiles.viewed(file("a.swift", "one, changed"), in: marks))
    marks = ViewedFiles.read(ViewedFiles.marking(b, true, in: marks, diffs: [b]))   // Staged on screen: a.swift isn't in it
    #expect(marks.keys.sorted() == ["a.swift", "b.swift"])
    #expect(ViewedFiles.viewed(a, in: marks))   // back to All Changes: still read
    marks = ViewedFiles.read(ViewedFiles.marking(a, false, in: marks, diffs: [a, b]))
    #expect(ViewedFiles.marking(b, false, in: marks, diffs: [b]).isEmpty)
    let many = Dictionary(uniqueKeysWithValues: (0..<ViewedFiles.kept).map { ("f\($0)", "x") })
    #expect(ViewedFiles.read(ViewedFiles.marking(b, true, in: many, diffs: [b])).keys.sorted() == ["b.swift"])
    // The print made with the rows is the one compared; a file not marked is never hashed.
    #expect(
        ViewedFiles.viewed(b, in: marks, printed: ViewedFiles.print(b))
            && !ViewedFiles.viewed(b, in: marks, printed: "other"))
    #expect(!ViewedFiles.viewed(a, in: marks, printed: ViewedFiles.print(a)))
}
