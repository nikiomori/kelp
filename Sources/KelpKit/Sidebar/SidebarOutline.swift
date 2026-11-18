import AppKit
import Core
import DesignKit

/// The sidebar's outline: a project, then its chats and groups in the same two columns (the slot under the project's
/// icon, the name under its name), since the card shows what the project holds. A group's chats sit 12 pt further in.
final class SidebarOutline: NSOutlineView {
    static let lead: CGFloat = 14, step: CGFloat = 12
    /// Extra indent steps beyond a row's level, for a group under the chat that made it and for that group's chats.
    var steps: (Int) -> Int = { _ in 0 }
    /// Room above and below a row's content, where the project's card opens and closes (SidebarRowView.group).
    var pads: (Int) -> (top: CGFloat, bottom: CGFloat) = { _ in (0, 0) }
    /// A row's own height, without that room (`SidebarRowView.content`). 0 while it isn't known.
    var rests: (Int) -> CGFloat = { _ in 0 }
    /// No disclosure triangles: projects and groups fold from the chevron their slot shows on hover (SidebarCell).
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var cellFrame = padded(super.frameOfCell(atColumn: column, row: row), row)
        // Content ends as far inside the card's right as a project's icon starts from its left (SidebarRowView.band).
        // Rows under a heading sit a step further in than those beside it, so the group ends at the indent.
        let left = Self.lead + Self.step * CGFloat((level(forRow: row) >= 2 ? 1 : 0) + steps(row))
        cellFrame.origin.x = left
        cellFrame.size.width = bounds.width - 8 - left
        return cellFrame
    }
    /// The row a right-click opened the menu for. `clickedRow` stays -1, see `menu(for:)`.
    private(set) var menuRow = -1
    /// Returns the menu without the outline NSTableView draws around the clicked row, which matched neither the pill
    /// nor the card. Instead the row keeps its hover pill until the menu closes (`menuClosed`).
    override func menu(for event: NSEvent) -> NSMenu? {
        menuRow = row(at: convert(event.locationInWindow, from: nil))
        (rowView(atRow: menuRow, makeIfNecessary: false) as? SidebarRowView)?.menuTarget = true
        return menu
    }
    func menuClosed() {
        let row = rowView(atRow: menuRow, makeIfNecessary: false) as? SidebarRowView
        row?.menuTarget = false
        row?.recheckPointer()   // the pointer may have left the row while the menu was open
        menuRow = -1
    }

    private func padded(_ cellFrame: NSRect, _ row: Int) -> NSRect {
        let pad = pads(row)
        return NSRect(
            x: cellFrame.minX, y: cellFrame.minY + pad.top, width: cellFrame.width,
            height: Self.rest(in: cellFrame.height, pad: pad, rest: rests(row)))
    }

    /// The height a row's content takes in a row `height` tall. It is the row's own height, hung from the card's top,
    /// while there is room for it: a project that folds or opens changes the room under its row at once, and the row
    /// takes a third of a second to follow, in which its name would ride down and back. A row with less room than
    /// that (one arriving from nothing) gets what its pads leave, as before.
    static func rest(in height: CGFloat, pad: (top: CGFloat, bottom: CGFloat), rest: CGFloat) -> CGFloat {
        rest > 0 && height - pad.top >= rest ? rest : height - pad.top - pad.bottom
    }
}
