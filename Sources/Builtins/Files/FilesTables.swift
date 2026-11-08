import AppKit
import DesignKit
import KelpKit

/// Finder's keys in the tree: Space previews, ↩ renames, ⌘⌫ moves to the Trash.
final class FilesOutline: ListOutlineView {
    var onSpace: (() -> Void)?, onReturn: (() -> Void)?, onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, mods) {
        case (49, []): onSpace?()
        case (36, []), (76, []): onReturn?()
        case (51, .command): onDelete?()
        default: super.keyDown(with: event)
        }
    }
}

/// Return in the results opens the line (a click does too).
final class ResultsTable: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let selector = action {
            NSApp.sendAction(selector, to: target, from: self)
            return
        }
        super.keyDown(with: event)
    }
}

/// The tree and the search results as the inspector's lists: rows 24 and 38 (with the text size), the rounded selection
/// (DesignKit's ListRowView), no background of their own over the panel.
extension FilesPanel {
    func styleLists() {
        for table in [outline, results] as [NSTableView] { table.rowSizeStyle = .custom }
        outline.rowHeight = TextSize.of(Metrics.row)
        outline.indentationPerLevel = 12
        results.rowHeight = TextSize.of(Metrics.rowTwoLine)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ListRowView() }
}
