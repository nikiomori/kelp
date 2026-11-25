import AppKit

/// ⌘Z for edits not yet saved: each change to `edits` (a cell, a row added or marked to be deleted, a paste, Discard)
/// goes on the window's undo manager, which puts the edits back as they were, and ⌘⇧Z makes the change again. Rows
/// read anew (`show`) can't be undone into.
extension ResultGrid {
    func editsChanged(from old: DatabaseEdits) {
        guard old != edits, let undo = table.undoManager else { return }
        // Outside an event's group (an answer that came later), the change is a group of its own
        let own = undo.groupingLevel == 0
        if own { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self) { grid in
            grid.edits = old   // which registers the redo
            grid.changed()
        }
        undo.setActionName(String(localized: "Edit"))
        if own { undo.endUndoGrouping() }
    }

    /// Forgets what the rows shown before could undo.
    func forgetUndo() { table.undoManager?.removeAllActions(withTarget: self) }
}
