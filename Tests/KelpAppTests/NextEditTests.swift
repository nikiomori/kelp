import AppKit
import DesignKit
import Foundation
import TestSupport
import Testing

@testable import EditorKit

private let thirty = (0..<30).map { "line \($0)" }

@Test func theModelSeesTheEditJustMadeAndTheCursorsLinesBeforeAndAfterIt() throws {
    var now = thirty
    now[12] = "LINE 12"
    now.insert("added", at: 13)
    let ask = try #require(
        NextEdit.ask(base: thirty.joined(separator: "\n"), now: now.joined(separator: "\n"), line: 12, earlier: []))
    #expect(ask.latest == NextEdit.Change(old: "line 12", new: "LINE 12\nadded"))
    #expect(ask.firstLine == 4)
    #expect(ask.current == now[4...20].joined(separator: "\n"))   // eight lines each side of the cursor
    #expect(ask.original == thirty[4...19].joined(separator: "\n"))   // the same lines, before the line was added
    #expect(NextEdit.ask(base: "same", now: "same", line: 0, earlier: []) == nil)   // no edit: nothing to ask
}

@Test(
    arguments: [
        // The window, the model's answer, and the lines it offers to change into what.
        ("a\nb\nc\nd", "a\nB\nc\nd", 1..<2, ["b"], ["B"]),   // a line written another way
        ("a\nb\nc\nd", "a\nb\nc\nnew\nd", 3..<3, [], ["new"]),   // a line added
        ("a\nb\nc\nd", "a\nc\nd", 1..<2, ["b"], []),   // a line taken away
        ("a\nb\nc\nd", "a\nb\nc\nd\n", nil, [], []),   // the same, with a line break more
        ("a\nb\nc\nd", "a\nb  \nc\nd", nil, [], []),   // only spaces at a line's end
        ("a\nb\nc\nd", "a\nb", nil, [], []),   // it stopped short: the window's end isn't taken away
        ("a\nb\n", "a\nb\nnew\n", 2..<2, [], ["new"])   // added before the window's own last line break
    ] as [(String, String, Range<Int>?, [String], [String])])
func anAnswerOffersTheLinesItChanged(current: String, answer: String, lines: Range<Int>?, old: [String], new: [String])
{
    let ask = NextEdit.Ask(
        earlier: [], latest: .init(old: "", new: ""), original: "", current: current, firstLine: 10)
    let proposal = NextEdit.proposal(answer, for: ask)
    #expect(proposal?.lines == lines.map { $0.lowerBound + 10..<$0.upperBound + 10 })
    if let proposal { #expect(proposal.old == old && proposal.new == new) }
}

@Test func aLineWrittenAnotherWayShowsOnlyWhatGoesAndWhatComes() {
    let (gone, put) = NextEdit.inline("folder.font = .systemFont(ofSize: 13)", "folder.font = .ui(13)")
    #expect(gone == NSRange(location: 15, length: 19))   // "systemFont(ofSize: "
    #expect(put == "ui(")
}

@Test(
    arguments: [
        (1..<2, ["B"], NSRange(location: 2, length: 2), "B\n"),
        (1..<2, [], NSRange(location: 2, length: 2), ""),
        (2..<2, ["new"], NSRange(location: 4, length: 0), "new\n"),
        (2..<3, ["C"], NSRange(location: 4, length: 1), "C"),   // the last line, which has no line break
        (3..<3, ["new"], NSRange(location: 5, length: 0), "\nnew")   // added after it: the break goes first
    ] as [(Range<Int>, [String], NSRange, String)])
func takingAnEditReplacesWholeLines(lines: Range<Int>, new: [String], range: NSRange, text: String) {
    let old = Array(["a", "b", "c"][lines])
    let got = NextEdit.replacement(.init(lines: lines, old: old, new: new), in: "a\nb\nc" as NSString)
    #expect(got.range == range)
    #expect(got.text == text)
}

@Test func aCRLFTextIsReadAndWrittenWithItsOwnLineBreaks() {
    #expect(NextEdit.lines("a\r\nb\r\n") == ["a", "b", ""])   // the model reads "\n" lines
    let text = "a\r\nb\r\nc" as NSString
    let changed = NextEdit.replacement(.init(lines: 1..<2, old: ["b"], new: ["B", "B2"]), in: text, lineBreak: "\r\n")
    #expect(changed.range == NSRange(location: 3, length: 3) && changed.text == "B\r\nB2\r\n")
    let added = NextEdit.replacement(.init(lines: 3..<3, old: [], new: ["d"]), in: text, lineBreak: "\r\n")
    #expect(added.range == NSRange(location: 7, length: 0) && added.text == "\r\nd")
}

extension OneAtATime {
    /// "⇥ to line N" grows with Settings › Appearance › Text size, so its words don't stick out of it.
    @Test func theJumpPillGrowsWithTheText() {
        defer { TextSize.apply(nil) }
        let pill = JumpPill()
        pill.label = "to line 14"
        let normal = pill.fitting
        TextSize.apply("larger")
        let grown = pill.fitting
        #expect(grown.height > normal.height && grown.width > normal.width)
        print("jump pill height", normal.height, "→", grown.height)
    }
}

@MainActor private enum KeptEditWindows { static var all: [NSWindow] = [] }

/// The next edit in a real editor: offered after an edit, ⇥ goes to it, ⇥ takes it, Esc drops one.
extension OneAtATime {
    @Test func tabGoesToTheEditOfferedThenTakesIt() async throws {
        _ = NSApplication.shared
        let text = "a.font = .systemFont(ofSize: 15)\nb.text = 1\nc.font = .systemFont(ofSize: 13)\n"
        let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/next.swift"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        KeptEditWindows.all.append(window)
        window.makeFirstResponder(e.textView)
        let tv = e.textView
        e.suggestionDelay = .zero
        e.suggestionProvider = { _ in nil }   // no gray text: the next edit is asked for
        var asked: NextEdit.Ask?
        e.nextEditProvider = { ask in
            asked = ask
            return ask.current.replacingOccurrences(of: ".systemFont(ofSize: 13)", with: ".ui(13)")
        }
        var events: [Bool] = []
        e.onNextEdit = { events.append($0) }
        tv.setSelectedRange(NSRange(location: 9, length: 23))   // ".systemFont(ofSize: 15)"
        tv.insertText(".ui(15)", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(try await waitFor(2) { e.isOfferingEdit })
        #expect(asked?.latest == NextEdit.Change(old: "a.font = .systemFont(ofSize: 15)", new: "a.font = .ui(15)"))
        #expect(e.nextEdit.pill?.isHidden == false)   // "⇥ to line 3", the cursor being on line 1
        #expect(e.nextEdit.struck == NSRange(location: 38, length: 19))

        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(tv.selectedRange() == NSRange(location: 38, length: 0))   // where line 3 changes
        #expect(e.nextEdit.pill?.isHidden == true)
        #expect(tv.string == "a.font = .ui(15)\nb.text = 1\nc.font = .systemFont(ofSize: 13)\n")   // not taken yet

        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(tv.string == "a.font = .ui(15)\nb.text = 1\nc.font = .ui(13)\n")
        #expect(tv.selectedRange().location == 44)   // after it
        #expect(!e.isOfferingEdit && e.nextEdit.struck == nil)
        #expect(events.prefix(2) == [true, false])

        e.nextEditProvider = { $0.current + "\nmore" }   // next, one that adds a line; Esc drops it
        tv.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(try await waitFor(2) { e.isOfferingEdit })
        tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!e.isOfferingEdit)
        #expect(tv.string == "a.font = .ui(15)\nb.text = 1\nc.font = .ui(13) \n")
    }

    @Test func anEditAnsweredAfterTheCursorLeftIsntOffered() async throws {
        let (e, tv) = editing("a.font = .systemFont(ofSize: 15)\nb.text = 1\nc.font = .systemFont(ofSize: 13)\n")
        var answer: CheckedContinuation<Void, Never>?
        e.nextEditProvider = { ask in
            await withCheckedContinuation { answer = $0 }
            return ask.current.replacingOccurrences(of: ".systemFont(ofSize: 13)", with: ".ui(13)")
        }
        tv.setSelectedRange(NSRange(location: 9, length: 23))
        tv.insertText(".ui(15)", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(try await waitFor(2) { answer != nil })
        tv.setSelectedRange(NSRange(location: 0, length: 0))   // a click elsewhere while the model writes
        answer?.resume()
        await e.nextEdit.task?.value
        #expect(!e.isOfferingEdit)
    }

    @Test func aFileWrittenFromOutsideIsntTheUsersEdit() async throws {
        let (e, tv) = editing("a = 1\nb = 2\nc = 3\n")
        var asked: [NextEdit.Ask] = []
        e.nextEditProvider = { ask in
            asked.append(ask)
            return nil
        }
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText("0", replacementRange: NSRange(location: NSNotFound, length: 0))   // a = 10
        #expect(try await waitFor(2) { asked.count == 1 })
        e.setText("a = 10\nb = 2\nc = 30\n")   // an agent changes line 3
        tv.insertText("0", replacementRange: NSRange(location: NSNotFound, length: 0))   // a = 100
        #expect(try await waitFor(2) { asked.count == 2 })
        #expect(asked.last?.latest == NextEdit.Change(old: "a = 10", new: "a = 100"))
        #expect(asked.last?.earlier == [NextEdit.Change(old: "a = 1", new: "a = 10")])   // only the user's
    }

    @Test func aBigFileIsAskedAboutTheSameLinesAsTheWholeFileGives() async throws {
        let text = (0..<50_000).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let (e, tv) = editing(text)
        var asked: NextEdit.Ask?
        e.nextEditProvider = { ask in
            asked = ask
            return nil
        }
        let at = (text as NSString).range(of: "let value25000 = 25000").location
        tv.setSelectedRange(NSRange(location: at + 3, length: 0))
        tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(try await waitFor(2) { asked != nil })
        let whole = { NextEdit.ask(base: text, now: tv.string, line: 25_000, earlier: []) }
        #expect(asked == whole())
        let clock = ContinuousClock()
        print(
            "next edit, 50 000 lines: the whole file split", clock.measure { _ = whole() },
            "; the lines around the edit", clock.measure { e.askNextEdit() })
    }

    /// An editor in a window, with no gray text, so edits ask for the next edit.
    private func editing(_ text: String) -> (CodeEditor, EditorTextView) {
        _ = NSApplication.shared
        let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/next.swift"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        KeptEditWindows.all.append(window)
        window.makeFirstResponder(e.textView)
        e.suggestionDelay = .zero
        e.suggestionProvider = { _ in nil }
        return (e, e.textView)
    }
}
