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
        let icon = NSImageView(image: .symbol("puzzlepiece.extension")); icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let t = NSTextField(labelWithString: String(localized: "Extension Turned Off")); t.font = .ui(13, weight: .semibold)
        let l = NSTextField(wrappingLabelWithString: String(localized: "The extension that shows “\(uri)” is turned off or was removed."))
        l.alignment = .center; l.textColor = .secondaryLabelColor
        let b = ClosureButton(title: String(localized: "Extensions…")) { SettingsWindow.show(app, section: "extensions") }; b.bezelStyle = .push
        let stack = NSStackView(views: [icon, t, l, b])
        stack.orientation = .vertical
        stack.spacing = 8
        let v = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: v.centerXAnchor), stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -32),
                                     l.widthAnchor.constraint(lessThanOrEqualToConstant: 420)])
        view = v
    }
    func focus() {}
}

@MainActor
extension NSMenu {
    /// Closure-backed item (keeps its target alive through representedObject).
    @discardableResult
    package func add(_ title: String, symbol: String? = nil, key: String = "", _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let t = ClosureTarget(action)
        let i = addItem(withTitle: title, action: #selector(ClosureTarget.fire), keyEquivalent: key)
        i.target = t; i.representedObject = t
        if let symbol { i.image = .symbol(symbol) }
        return i
    }
}

/// A double-click on a divider shares that split equally (like Terminal's and Ghostty's splits).
final class EqualizingSplitView: NSSplitView {
    override func mouseDown(with e: NSEvent) {
        guard e.clickCount == 2, arrangedSubviews.count > 1 else { return super.mouseDown(with: e) }
        let p = convert(e.locationInWindow, from: nil)
        let onDivider = arrangedSubviews.dropLast().contains { v in
            let f = v.frame
            return isVertical ? abs(p.x - f.maxX) <= dividerThickness + 3 : abs(p.y - f.maxY) <= dividerThickness + 3
        }
        guard onDivider else { return super.mouseDown(with: e) }
        let total = (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(arrangedSubviews.count - 1)
        let share = total / CGFloat(arrangedSubviews.count)
        for i in 0..<(arrangedSubviews.count - 1) { setPosition(share * CGFloat(i + 1) + dividerThickness * CGFloat(i), ofDividerAt: i) }
    }
}
