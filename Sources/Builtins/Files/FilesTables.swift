import AppKit
import DesignKit
import KelpKit

/// Finder's keys in the tree: Space previews, ↩ renames, ⌘⌫ moves to the Trash.
final class FilesOutline: ListOutlineView {
    var onSpace: (() -> Void)?, onReturn: (() -> Void)?, onDelete: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (e.keyCode, mods) {
        case (49, []): onSpace?()
        case (36, []), (76, []): onReturn?()
        case (51, .command): onDelete?()
        default: super.keyDown(with: e)
        }
    }
}

/// Return in the results opens the line (a click does too).
final class ResultsTable: NSTableView {
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36 || e.keyCode == 76, let a = action { NSApp.sendAction(a, to: target, from: self); return }
        super.keyDown(with: e)
    }
}

/// The tree and the search results as the inspector's lists: rows 24 and 38 (with the text size), the rounded selection
/// (DesignKit's ListRowView), no background of their own over the panel.
extension FilesPanel {
    func styleLists() {
        for t in [outline, results] as [NSTableView] {
            t.style = .plain
            t.backgroundColor = .clear
            t.rowSizeStyle = .custom
        }
        outline.rowHeight = TextSize.of(Metrics.row)
        outline.indentationPerLevel = 12
        results.rowHeight = TextSize.of(Metrics.rowTwoLine)
    }

    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ListRowView() }
}
