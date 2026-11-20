import AppKit
import DesignKit

/// Unsaved files ask before what would drop them: quitting, or closing, archiving or removing their workspace.
@MainActor
enum UnsavedChanges {
    /// The alert that asks: Save (or Save All), Cancel when `canCancel` (not once the workspace is already gone), and
    /// Don't Save.
    static func alert(_ edited: [SavableTab], quitting: Bool, canCancel: Bool = true) -> NSAlert {
        let alert = NSAlert()
        alert.messageText =
            edited.count == 1
            ? String(localized: "Do you want to save the changes you made to “\(edited[0].title)”?")
            : quitting
                ? String(localized: "You have \(edited.count) files with unsaved changes. Save them before quitting?")
                : String(localized: "You have \(edited.count) files with unsaved changes. Save them before closing?")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: edited.count == 1 ? String(localized: "Save") : String(localized: "Save All"))
        if canCancel { alert.addButton(withTitle: String(localized: "Cancel")) }
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        return alert
    }

    /// Returns true to go on: every file was saved, or the user chose to lose the changes. A save still on its way
    /// counts as saved here, so await `written` before whatever would end it.
    static func settle(_ edited: [SavableTab], _ answer: NSApplication.ModalResponse, canCancel: Bool = true) async
        -> Bool
    {
        if answer == .alertFirstButtonReturn {
            for tab in edited { guard await tab.save() else { return false } }   // one at a time: each may ask (Save Here, a name)
            return true
        }
        guard answer == (canCancel ? .alertThirdButtonReturn : .alertSecondButtonReturn) else { return false }
        edited.forEach { $0.discard() }
        return true
    }

    /// Asks before workspaces close, are archived, or leave with their project; returns true to go on.
    static func confirm(closing ids: [String], in app: AppModel) async -> Bool {
        let edited = app.workbench.editors?.editedFiles(in: ids) ?? []
        guard !edited.isEmpty else { return true }
        guard await settle(edited, await runSheet(alert(edited, quitting: false))) else { return false }
        return await written(edited)
    }

    /// Waits for saves still on their way (remote files), and returns true when nothing is left unsaved.
    static func written(_ tabs: [SavableTab]) async -> Bool {
        for tab in tabs { await tab.pendingSave?.value }
        return tabs.allSatisfy { !$0.isEdited }
    }
}
