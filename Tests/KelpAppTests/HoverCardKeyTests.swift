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

/// A card that isn't up stops looking for the pointer, even with the pointer over where its view is: it used to look
/// again every 0.2 s for as long as the pointer rested there.
@MainActor @Test func aCardNotUpStopsLookingForThePointer() {
    let card = HoverPopover(), content = NSViewController()
    content.view = NSView()
    let at = NSEvent.mouseLocation
    let window = NSWindow(
        contentRect: NSRect(x: at.x - 50, y: at.y - 50, width: 100, height: 100), styleMask: [.borderless],
        backing: .buffered, defer: true)
    window.contentView = content.view
    card.popover.contentViewController = content
    var closed = false
    card.onClose = { closed = true }
    card.closeUnlessInside()
    #expect(closed)
    #expect(!card.isShown)
}
