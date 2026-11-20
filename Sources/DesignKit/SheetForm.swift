import AppKit

/// The one layout of a sheet that asks for something. Its parts go top to bottom, `sheetInset` from every edge. A
/// field's name is right-aligned in a column of `formLabel`, without a colon, as Settings rows have it. Every field,
/// list, note and the buttons' row is as wide as the sheet's inside, so the fields end where the buttons end.
@MainActor
public enum SheetForm {
    /// The names and their fields. Fields stretch to the end once `stack` lays the grid out.
    public static func grid(_ rows: [(String, NSView)]) -> NSGridView {
        // Names in `body`, as the sheet's other words and its fields, growing with Text size.
        let grid = NSGridView(views: rows.map { [NSTextField.label($0.0, font: .ui(TextSize.body)), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Metrics.formLabel
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = Metrics.gapWide
        grid.columnSpacing = Metrics.gapWide
        return grid
    }

    /// Stacks `parts` for a sheet `width` wide. A grid's fields, and the parts in `wide`, take the whole inside.
    public static func stack(_ parts: [NSView], wide: [NSView], width: CGFloat) -> NSStackView {
        let inside = width - 2 * Metrics.sheetInset
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.inset
        stack.detachesHiddenViews = true
        let inset = Metrics.sheetInset
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        for view in wide {
            view.widthAnchor.constraint(equalToConstant: inside).isActive = true
            (view as? NSTextField)?.preferredMaxLayoutWidth = inside   // a note wraps at the sheet's edge, not past it
        }
        for grid in parts.compactMap({ $0 as? NSGridView }) {
            for row in 0..<grid.numberOfRows {
                grid.cell(atColumnIndex: 1, rowIndex: row).contentView?.widthAnchor
                    .constraint(equalToConstant: inside - Metrics.formLabel - grid.columnSpacing).isActive = true
            }
        }
        return stack
    }

    /// Sizes a sheet to its `stack` after parts show or hide. It grows or shrinks smoothly from its top edge, which
    /// hangs from the window's title bar: at once before it shows and under Reduce Motion. Call it once the stack is
    /// the sheet's content, and after each change.
    public static func fit(_ window: NSWindow?) {
        guard let window, let stack = window.contentView as? NSStackView else { return }
        // Below the window's own priority, so new parts don't snap the sheet taller: the frame below grows it.
        stack.setClippingResistancePriority(.windowSizeStayPut - 10, for: .vertical)
        let width = window.contentRect(forFrameRect: window.frame).width
        var frame = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: width, height: stack.fittingSize.height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        guard window.isVisible else { return window.setFrame(frame, display: true) }
        // Grows on `base`; closes up in about two thirds of that, easing in, as what leaves does.
        let shrinks = frame.height < window.frame.height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(shrinks ? Motion.base * 2 / 3 : Motion.base)
            if shrinks { context.timingFunction = CAMediaTimingFunction(name: .easeIn) }
            window.animator().setFrame(frame, display: true)
        }
    }
}
