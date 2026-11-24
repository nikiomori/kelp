import AppKit
import DesignKit
import Testing

/// A hover card copies its selected words on ⌘C (and stays) but closes on any other key: only ⌘C alone is a copy.
@MainActor @Test func onlyCommandCIsACardsCopy() {
    func key(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 8)!
    }
    #expect(key("c", .command).isCopy)
    #expect(!key("c", []).isCopy)
    #expect(!key("c", [.command, .shift]).isCopy)
    #expect(!key("v", .command).isCopy)
}
