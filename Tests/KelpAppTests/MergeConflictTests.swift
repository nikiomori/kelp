import AppKit
import DesignKit
import Foundation
import Testing

@testable import BuiltinFiles
@testable import EditorKit

private let twoConflicts = """
    top
    <<<<<<< HEAD
    mine
    =======
    theirs
    >>>>>>> feature
    middle
    <<<<<<< ours
    a
    ||||||| base
    o
    =======
    b
    >>>>>>> theirs
    end

    """

/// Git's blocks, the diff3 one with its base too; markers only where git writes them.
@Test func mergeConflictsAreFoundWhereGitWritesThem() {
    let found = MergeConflict.all(in: twoConflicts)
    #expect(found.count == 2)
    let s = twoConflicts as NSString
    #expect(found.map { s.substring(with: $0.current) } == ["mine\n", "a\n"])
    #expect(found.map { s.substring(with: $0.incoming) } == ["theirs\n", "b\n"])
    #expect(s.substring(with: found[0].whole).hasPrefix("<<<<<<< HEAD\n"))
    #expect(s.substring(with: found[0].whole).hasSuffix(">>>>>>> feature\n"))
    // A Markdown heading's underline, an unfinished block, a longer run of the same letter: none is a conflict.
    #expect(MergeConflict.all(in: "Title\n=======\n").isEmpty)
    #expect(MergeConflict.all(in: "<<<<<<< HEAD\nmine\n=======\ntheirs\n").isEmpty)
    #expect(MergeConflict.all(in: "<<<<<<<< x\na\n=======\nb\n>>>>>>> y\n").isEmpty)
    #expect(MergeConflict.all(in: "plain text\n").isEmpty)
}

@Test func aConflictResolvesToEitherSideOrBoth() {
    let first = MergeConflict.all(in: twoConflicts)[0]
    #expect(first.resolving(twoConflicts, keeping: .current).hasPrefix("top\nmine\nmiddle\n"))
    #expect(first.resolving(twoConflicts, keeping: .incoming).hasPrefix("top\ntheirs\nmiddle\n"))
    #expect(first.resolving(twoConflicts, keeping: .both).hasPrefix("top\nmine\ntheirs\nmiddle\n"))
}

/// The bar over the file: one conflict accepted at a time, each undoable; hidden once none is left.
@MainActor @Test func theConflictBarResolvesOneAtATime() {
    let e = CodeEditor(text: twoConflicts, url: URL(fileURLWithPath: "/t.txt"))
    let bar = ConflictBar(editor: e)
    #expect(!bar.bar.isHidden)
    bar.bar.stack.views.compactMap { $0 as? TextButton }.first { $0.title == "Accept Incoming" }?.performClick(nil)
    #expect(e.text.hasPrefix("top\ntheirs\nmiddle\n<<<<<<< ours"))
    #expect(!bar.bar.isHidden)
    bar.bar.stack.views.compactMap { $0 as? TextButton }.first { $0.title == "Accept Both" }?.performClick(nil)
    #expect(e.text == "top\ntheirs\nmiddle\na\nb\nend\n")
    #expect(bar.bar.isHidden)
    e.textView.undoManager?.undo()
    bar.refresh()
    #expect(e.text.contains("||||||| base") && !bar.bar.isHidden)
}

/// A keystroke reads the file for conflicts again only when there are some, or it could make or break a marker line: a
/// marker's character or a line break in it, or within a line's first eight characters (they tell a marker).
@MainActor @Test func aKeystrokeLooksForConflictsOnlyWhereItCouldMakeOne() {
    #expect(!ConflictBar.couldMark((column: 20, removed: "", inserted: "a")))
    #expect(ConflictBar.couldMark((column: 20, removed: "", inserted: "=")))
    #expect(ConflictBar.couldMark((column: 20, removed: "\r\n", inserted: "")))
    #expect(ConflictBar.couldMark((column: 3, removed: "x", inserted: "")))
    let e = CodeEditor(
        text: "x<<<<<<< ours\nmine\n=======\ntheirs\n>>>>>>> feature\n", url: URL(fileURLWithPath: "/c.txt"))
    let bar = ConflictBar(editor: e)
    #expect(bar.bar.isHidden)
    e.textView.replace([NSRange(location: 49, length: 0)], with: ["s"])   // "features": nothing to look for
    bar.edited(e.lastEdit)
    #expect(bar.bar.isHidden)
    e.textView.replace([NSRange(location: 0, length: 1)], with: [""])   // the x before the marker goes: a conflict
    bar.edited(e.lastEdit)
    #expect(!bar.bar.isHidden)
}
