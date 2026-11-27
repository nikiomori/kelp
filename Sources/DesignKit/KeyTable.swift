import AppKit

extension NSTableView {
    /// The row an action is about: the clicked one, or the selected one when the keys sent the action.
    public var actedRow: Int { clickedRow >= 0 ? clickedRow : selectedRow }
}

/// A list's table that answers Return (or Enter) and Space, as Finder's lists do: Return opens the selected row, as a
/// double click does, and Space shows it in Quick Look; ⌫ deletes it, as in Mail. A key with nothing set goes on to the
/// table.
@MainActor
public final class KeyTable: NSTableView {
    public var onReturn: (() -> Void)?, onSpace: (() -> Void)?, onDelete: (() -> Void)?
    /// The modifiers held with the Return `onReturn` answers (⌘ or ⇧ may mean another action).
    public private(set) var returnModifiers: NSEvent.ModifierFlags = []

    override public func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.isDisjoint(with: [.command, .option, .control])
        if [36, 76].contains(event.keyCode), let onReturn {
            returnModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            onReturn()
        } else if event.keyCode == 49, plain, let onSpace {
            onSpace()
        } else if [51, 117].contains(event.keyCode), let onDelete {
            onDelete()
        } else {
            super.keyDown(with: event)
        }
    }
}
