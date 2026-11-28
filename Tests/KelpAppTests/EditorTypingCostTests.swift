import AppKit
import Foundation
import TestSupport
import Testing

@testable import BuiltinFiles
@testable import EditorKit
@testable import KelpKit

/// Windows the editors sit in for a test: kept, as a view only holds its window weakly.
@MainActor private enum Shown { static var windows: [NSWindow] = [] }

/// What a keystroke, a look and the disk cost an editor: only what changed is done again.
extension OneAtATime {
    private func shown(_ text: String, _ name: String) -> CodeEditor {
        _ = NSApplication.shared
        let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/" + name))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        Shown.windows.append(window)
        return e
    }

    private func drained() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }

    /// In a long file the parse comes in a moment after the key: the colors already there stay (they move with the edit),
    /// and the screen is colored once, from the new tree, instead of from the old one first.
    @Test func aLongFilesKeyWaitsForItsParseToColor() async throws {
        // A fifth longer than the longest text parsed on the main thread.
        let line = "let value = 1 // one\n", lines = SyntaxHighlighter.syncLimit * 6 / 5 / line.utf16.count
        let e = shown(String(repeating: line, count: lines), "long.swift")
        #expect(try await waitFor(10) { e.highlighter?.waiting == false && e.colored != nil })
        e.textView.setSelectedRange(NSRange(location: 4, length: 0))
        e.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(e.highlighter?.waiting == true)
        #expect(e.colored != nil)   // not thrown away for a pass with the old tree
        #expect(try await waitFor(10) { e.highlighter?.waiting == false && e.colored != nil })
    }

    /// The same look again (a setting read back, a tab's own wrap at open) leaves the text's attributes alone: they went
    /// over the whole of a 5 MB file each time.
    @Test func theSameLookAgainTouchesNoText() {
        let e = shown("let a = 1\n", "look.swift")
        nonisolated(unsafe) var edits = 0   // posted on this thread, as the edits happen
        let seen = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: e.textView.textStorage, queue: nil
        ) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(seen) }
        e.refreshAppearance()
        #expect(edits == 0)
        e.useIndent(tabWidth: 2, spaces: true)   // a new tab width: all of it
        #expect(edits == 1)
    }

    /// A see-through theme's editor lets what's under it show: a scroll view filling its background calls itself
    /// opaque, and AppKit painted it grey whatever the colour's alpha. An opaque theme keeps the fill.
    @Test func aSeeThroughLookLeavesTheEditorUnfilled() {
        let was = CodeEditor.current
        defer { CodeEditor.apply(look: was) }
        let e = shown("let a = 1\n", "through.swift")
        for (background, filled) in [("#1211191f", false), ("#121119", true)] {
            var look = was
            look.palette = .init(background: background, text: "#eef0f6")
            CodeEditor.apply(look: look)
            e.refreshAppearance()
            #expect(e.scroll.drawsBackground == filled && e.scroll.isOpaque == filled, "\(background)")
        }
    }

    /// An empty range, as a hidden or squeezed editor's screen is, costs nothing to color: tree-sitter takes a range
    /// ending at 0 for one with no end, and the whole file was queried on the main thread after each parse.
    @Test func anEmptyRangeCostsNothingToColor() async throws {
        let e = shown(String(repeating: "let value = compute(index: 42) // a line\n", count: 20_000), "empty.swift")
        let h = try #require(e.highlighter)
        #expect(try await waitFor(10) { h.tree != nil && !h.waiting })   // parsed off the main thread
        let all = NSRange(location: 0, length: e.textView.string.utf16.count)
        let clock = ContinuousClock()
        let whole = clock.measure { h.color(all, in: e.textView) }
        let empty = clock.measure { h.color(NSRange(location: 0, length: 0), in: e.textView) }
        #expect(empty * 20 < whole, "\(empty) against \(whole)")
    }

    /// A look given while an editor is off screen (its tab hidden) waits until it shows.
    @Test func aHiddenEditorTakesANewLookWhenShown() {
        _ = NSApplication.shared
        let was = CodeEditor.current
        defer { CodeEditor.apply(look: was) }
        let e = CodeEditor(text: "let a = 1\n", url: URL(fileURLWithPath: "/tmp/hidden.swift"))
        func size() -> CGFloat? {
            (e.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        }
        let before = size()
        var look = was
        look.fontSize = was.fontSize + 5
        CodeEditor.apply(look: look)
        #expect(size() == before)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        Shown.windows.append(window)
        #expect(size() == look.fontSize)
    }

    /// An edit below the top line on screen leaves the sticky scopes as they were found; one above it, or a scroll, finds
    /// them again.
    @Test func anEditBelowTheTopLineKeepsTheStickyScopes() async {
        let e = shown("func a() {\n" + String(repeating: "    let x = 1\n", count: 300) + "}\n", "sticky.swift")
        e.scroll(toLine: 100)
        await drained()
        #expect(e.stickyTop == e.topLine)
        let string = e.textView.string as NSString
        let below = string.range(of: "let", options: [], range: NSRange(location: 2000, length: string.length - 2000))
        #expect(e.stickyHolds(after: below.location))
        #expect(!e.stickyHolds(after: 3))   // in the scope's own line
        #expect(!e.stickyHolds(after: nil))   // a scroll
    }

    /// A Markdown heading's section: to the next heading as high or higher, wherever its hashes start; a hashtag or a lone
    /// hash isn't one.
    @Test func aMarkdownSectionEndsAtTheNextHeadingAsHigh() {
        let text = "# A\ntext\n#tag\n#\n## B\nmore\n  # C\nlast\n" as NSString
        let first = Folds.section(text.lineRange(for: NSRange(location: 0, length: 0)), in: text, markdown: true)
        #expect(first.map { text.substring(with: $0) } == "\ntext\n#tag\n#\n## B\nmore")
        let b = text.range(of: "## B")
        let second = Folds.section(text.lineRange(for: b), in: text, markdown: true)
        #expect(second.map { text.substring(with: $0) } == "\nmore")
        #expect(Folds.headingLevel(text.lineRange(for: text.range(of: "#tag")), in: text) == nil)
        #expect(Folds.headingLevel(text.lineRange(for: text.range(of: "  # C")), in: text) == 1)
    }

    /// What two long texts don't share, found a piece at a time: edits on either side of a piece's edge, at the very ends.
    @Test func whatTwoLongTextsDontShareIsFoundPieceByPiece() {
        let base = String(repeating: "abcdefghij", count: 1_000) as NSString   // 10 000, past two pieces
        func after(_ at: Int, _ cut: Int, _ put: String) -> NSString {
            base.replacingCharacters(in: NSRange(location: at, length: cut), with: put) as NSString
        }
        /// Character by character, as it was.
        func plainly(_ a: NSString, _ b: NSString) -> (NSRange, NSRange) {
            let shorter = min(a.length, b.length)
            var head = 0, tail = 0
            while head < shorter, a.character(at: head) == b.character(at: head) { head += 1 }
            while tail < shorter - head, a.character(at: a.length - 1 - tail) == b.character(at: b.length - 1 - tail) {
                tail += 1
            }
            return (
                NSRange(location: head, length: a.length - head - tail),
                NSRange(location: head, length: b.length - head - tail)
            )
        }
        for (at, cut, put) in [(4095, 2, "XY"), (4096, 0, "Z"), (0, 1, ""), (9_999, 1, "end"), (5_000, 3_000, "")] {
            let (old, new) = CodeEditor.changed(base, after(at, cut, put))
            #expect((old, new) == plainly(base, after(at, cut, put)))
            #expect(
                base.replacingCharacters(in: old, with: after(at, cut, put).substring(with: new)) == after(at, cut, put)
                    as String)
        }
        #expect(
            CodeEditor.changed(base, base) == (
                NSRange(location: 10_000, length: 0), NSRange(location: 10_000, length: 0)
            ))
    }
}
