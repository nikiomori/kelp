import AppKit
import Core
import DesignKit

/// A tab whose provider is missing (its extension is disabled or uninstalled).
@MainActor
final class UnavailableTab: TabContent {
    let uri: String
    let view: NSView
    var title: String { String(localized: "Turned Off") }
    var icon: NSImage? { .symbol("questionmark.square.dashed") }
    init(uri: String, app: AppModel) {
        self.uri = uri
        let icon = NSImageView(image: .symbol("puzzlepiece.extension"))
        icon.symbolConfiguration = .chrome(Metrics.iconEmpty)
        icon.contentTintColor = .tertiaryLabelColor
        let heading = NSTextField(labelWithString: String(localized: "Extension Turned Off"))
        heading.font = .ui(13, weight: .semibold)
        let message = NSTextField(
            wrappingLabelWithString: String(
                localized: "The extension that shows “\(uri)” is turned off or was removed."))
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        let button = ClosureButton(title: String(localized: "Extensions…")) {
            SettingsWindow.show(app, section: "extensions")
        }
        button.bezelStyle = .push
        let stack = NSStackView(views: [icon, heading, message, button])
        stack.orientation = .vertical
        stack.spacing = 8
        let content = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        view = content
    }
    func focus() {}
}

@MainActor
extension NSMenu {
    /// Closure-backed item (keeps its target alive through representedObject).
    @discardableResult
    package func add(
        _ title: String, symbol: String? = nil, key: String = "", _ action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let target = ClosureTarget(action)
        let item = addItem(withTitle: title, action: #selector(ClosureTarget.fire), keyEquivalent: key)
        item.target = target
        item.representedObject = target
        if let symbol { item.image = .symbol(symbol) }
        return item
    }
}

extension NSMenuItem {
    /// An image that says something, kept on macOS 27, whose menus hide the ones an item doesn't ask to show.
    package func show(_ image: NSImage?) {
        self.image = image
        #if compiler(>=6.4)   // the macOS 27 SDK
            if #available(macOS 27, *) { preferredImageVisibility = .visible }
        #endif
    }

    /// A name, and in grey at `column` what tells it apart.
    package static func titleWithNote(
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

    /// The longest name's width and a gap: where the grey notes start.
    package static func noteColumn(_ names: [String]) -> CGFloat {
        (names.map { ($0 as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width }.max() ?? 0)
            + Metrics.inset
    }
}

/// A double-click on a divider shares that split equally (like Terminal's and Ghostty's splits).
final class EqualizingSplitView: NSSplitView {
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, arrangedSubviews.count > 1 else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let onDivider = arrangedSubviews.dropLast().contains { pane in
            let paneFrame = pane.frame
            return isVertical
                ? abs(point.x - paneFrame.maxX) <= dividerThickness + 3
                : abs(point.y - paneFrame.maxY) <= dividerThickness + 3
        }
        guard onDivider else { return super.mouseDown(with: event) }
        let total = (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(arrangedSubviews.count - 1)
        let share = total / CGFloat(arrangedSubviews.count)
        for index in 0..<(arrangedSubviews.count - 1) {
            setPosition(share * CGFloat(index + 1) + dividerThickness * CGFloat(index), ofDividerAt: index)
        }
    }
}
