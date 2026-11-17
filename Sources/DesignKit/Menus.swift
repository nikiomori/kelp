import AppKit

@MainActor
extension NSMenu {
    /// Adds an item backed by a closure (the item keeps its target alive through representedObject).
    @discardableResult
    public func add(
        _ title: String, symbol: String? = nil, key: String = "", _ action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let target = ClosureTarget(action)
        let item = addItem(withTitle: title, action: #selector(ClosureTarget.fire), keyEquivalent: key)
        item.target = target
        item.representedObject = target
        if let symbol { item.image = .symbol(symbol) }
        return item
    }

    /// Adds an item that opens `submenu`.
    @discardableResult
    public func add(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let item = addItem(withTitle: title, action: nil, keyEquivalent: "")
        setSubmenu(submenu, for: item)
        return item
    }
}

extension NSMenuItem {
    /// Sets an image that says something, so it is kept on macOS 27, whose menus hide the images an item doesn't ask to
    /// show.
    public func show(_ image: NSImage?) {
        self.image = image
        #if compiler(>=6.4)   // the macOS 27 SDK
            if #available(macOS 27, *) { preferredImageVisibility = .visible }
        #endif
    }

    /// A name, and at `column`, in grey, what tells it apart.
    public static func titleWithNote(
        _ name: String, note: String, column: CGFloat, dim: Bool = false, noteColor: NSColor = .secondaryLabelColor
    ) -> NSAttributedString {
        let tab = NSMutableParagraphStyle()
        tab.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        let text = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0), .paragraphStyle: tab,
                .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor
            ])
        text.append(
            NSAttributedString(
                string: "\t" + note,
                attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: tab, .foregroundColor: noteColor]))
        return text
    }

    /// Where the grey notes start: the longest name's width and a gap.
    public static func noteColumn(_ names: [String]) -> CGFloat {
        (names.map { ($0 as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width }.max() ?? 0)
            + Metrics.inset
    }
}
