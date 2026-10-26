import AppKit
import EditorKit

/// Holds a file's editor. While the editor has the focus its commands (`editor.…`) get their keys before the menu bar,
/// which gives a key to the first item that has it, on or off: ⌘D is Add Next Occurrence here and Split Right elsewhere.
final class EditorBox: NSView {
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard CodeEditor.focused != nil, let item = Self.editorItem(for: e, in: NSApp.mainMenu), let action = item.action else {
            return super.performKeyEquivalent(with: e)
        }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func editorItem(for e: NSEvent, in menu: NSMenu?) -> NSMenuItem? {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        for i in menu?.items ?? [] {
            if let found = editorItem(for: e, in: i.submenu) { return found }
            let key = i.keyEquivalent, shift: NSEvent.ModifierFlags = key != key.lowercased() ? .shift : []
            if i.identifier?.rawValue.hasPrefix("editor.") == true, !key.isEmpty, key.lowercased() == e.charactersIgnoringModifiers?.lowercased(),
               i.keyEquivalentModifierMask.union(shift).intersection([.command, .shift, .option, .control]) == mods { return i }
        }
        return nil
    }
}
