import AppKit
import DesignKit
import Testing

@testable import KelpKit

/// A modified click (⌘ on a row's PR or CI mark, a CI run, an item in Issues & PRs; ⌥ on a chat's row) counts only
/// with exactly its keys held and only for a left click: ⌘⇧ is a list's pick, and a key press with ⌘ is a shortcut.
@MainActor @Test func aModifiedClickCountsOnlyWithExactlyItsKeys() throws {
    let cases: [(NSEvent.EventType, NSEvent.ModifierFlags, NSEvent.ModifierFlags, Bool)] = [
        (.leftMouseUp, .command, .command, true),
        (.leftMouseDown, [.option, .capsLock], .option, true),
        (.leftMouseUp, [.command, .shift], .command, false),
        (.leftMouseUp, .command, .option, false),
        (.leftMouseUp, [], .command, false),
        (.rightMouseUp, .command, .command, false)
    ]
    for (type, held, keys, counts) in cases {
        let click = try #require(
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: held, timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(click.isClick(with: keys) == counts, "\(type) \(held) as \(keys)")
    }
    let press = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    #expect(!press.isClick(with: .command))
}
