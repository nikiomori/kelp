import AppKit
import EditorKit

/// Holds a file's editor. While the editor has the focus, its commands (`editor.…`) get their keys before the menu bar
/// does. The menu bar gives a key to the first item that has it, enabled or not, and ⌘D is Add Next Occurrence here but
/// New Terminal to the Right elsewhere.
final class EditorBox: NSView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard CodeEditor.focused != nil, let item = Self.editorItem(for: event, in: NSApp.mainMenu),
            let action = item.action
        else {
            return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func editorItem(for event: NSEvent, in menu: NSMenu?) -> NSMenuItem? {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        for i in menu?.items ?? [] {
            if let found = editorItem(for: event, in: i.submenu) { return found }
            let key = i.keyEquivalent, shift: NSEvent.ModifierFlags = key != key.lowercased() ? .shift : []
            if i.identifier?.rawValue.hasPrefix("editor.") == true, !key.isEmpty,
                key.lowercased() == event.charactersIgnoringModifiers?.lowercased(),
                i.keyEquivalentModifierMask.union(shift).intersection([.command, .shift, .option, .control]) == mods
            {
                return i
            }
        }
        return nil
    }
}
