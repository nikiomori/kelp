import AppKit
import Foundation
import Testing

@testable import EditorKit
@testable import KelpKit

/// Windows the editors sit in for a test: kept, as a view only holds its window weakly.
@MainActor private enum Kept { static var windows: [NSWindow] = [] }

/// ⌘ over a word links to its definition: underlined while held, opened by a click (⌥⌘: beside).
extension OneAtATime {
    private func editor(_ text: String) -> (CodeEditor, EditorTextView) {
        _ = NSApplication.shared
        let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/link.swift"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        Kept.windows.append(window)
        e.textView.setCursors([NSRange(location: 0, length: 0)])
        return (e, e.textView)
    }

    /// The middle of the character at `index`, in the view's coordinates.
    private func point(_ tv: EditorTextView, _ index: Int) -> NSPoint {
        let lm = tv.layoutManager!, tc = tv.textContainer!
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        return NSPoint(x: box.midX + tv.textContainerOrigin.x, y: box.midY + tv.textContainerOrigin.y)
    }

    private func event(_ type: NSEvent.EventType, _ tv: EditorTextView, _ index: Int, _ flags: NSEvent.ModifierFlags)
        -> NSEvent
    {
        NSEvent.mouseEvent(
            with: type, location: tv.convert(point(tv, index), to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: tv.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func underlined(_ tv: EditorTextView) -> [Int] {
        (0..<tv.length).filter {
            tv.layoutManager!.temporaryAttribute(.underlineStyle, atCharacterIndex: $0, effectiveRange: nil) != nil
        }
    }

    @Test func onlyCommandAndOptionCommandMakeALink() {
        let cases: [(NSEvent.ModifierFlags, Bool?)] = [
            (.command, false), ([.command, .option], true), ([.command, .capsLock], false), ([], nil), (.option, nil),
            ([.command, .shift], nil), ([.command, .control], nil)
        ]
        for (flags, beside) in cases { #expect(DefinitionLink.beside(flags) == beside) }
    }

    /// The cursor goes to the character clicked, then the definition is asked for; ⌥⌘ asks for it beside.
    @Test func commandClickOnAWordJumpsFromThere() {
        let (e, tv) = editor("let x = foo()\n")
        var asked: [(Bool, Int)] = []
        e.onDefinition = { asked.append(($0, tv.selectedRange().location)) }
        tv.mouseDown(with: event(.leftMouseDown, tv, 9, .command))
        tv.mouseDown(with: event(.leftMouseDown, tv, 4, [.command, .option]))
        #expect(asked.map(\.0) == [false, true])
        #expect(asked.map(\.1) == [9, 4])
    }

    @Test func commandOverAWordUnderlinesItUntilLetGo() {
        let (e, tv) = editor("let x = foo()\n")
        e.onDefinition = { _ in }
        tv.mouseMoved(with: event(.mouseMoved, tv, 9, .command))
        #expect(underlined(tv) == [8, 9, 10])
        tv.mouseMoved(with: event(.mouseMoved, tv, 11, .command))   // "(" is no name
        #expect(underlined(tv).isEmpty)
        tv.mouseMoved(with: event(.mouseMoved, tv, 1, .command))
        #expect(underlined(tv) == [0, 1, 2])
        tv.link.update(tv, at: point(tv, 1), [])   // ⌘ let go, the pointer still there
        #expect(underlined(tv).isEmpty)
    }

    /// With no language server nothing is a link, and a ⌘-click is left to be a plain click.
    @Test func withNoServerNothingIsALink() {
        let (_, tv) = editor("let x = foo()\n")
        tv.mouseMoved(with: event(.mouseMoved, tv, 9, .command))
        #expect(underlined(tv).isEmpty)
        #expect(!tv.link.open(tv, at: point(tv, 9), event(.leftMouseDown, tv, 9, .command)))
        #expect(DefinitionLink.plain(event(.leftMouseDown, tv, 9, [.command, .option])).modifierFlags.isEmpty)
    }
}
