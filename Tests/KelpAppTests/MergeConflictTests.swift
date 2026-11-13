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
