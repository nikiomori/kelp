import AppKit
import DesignKit
import KelpKit

/// The panel's bar: what it lists (source and filter as title words) and Refresh, the last action's word under it.
extension TasksViewController {
    func makeBar() -> NSView {
        let more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More"), target: self, action: #selector(showMore(_:)))
        status.textColor = .secondaryLabelColor; status.font = .ui(11)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Popups that read as the panel's title words, not as two buttons the width of the panel.
        for c in [source, filter] {
            c.controlSize = .small
            c.isBordered = false
            c.font = .ui(12, weight: .semibold)
            c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        filter.font = .ui(12)
        // An inspector panel: its bar (what it lists, ⋯), the last action's word under it, the list over the details.
        let controls = Bar.panel([source, filter], [more])
        status.isHidden = true
        let bar = NSStackView(views: [controls, status])
        bar.orientation = .vertical
        bar.spacing = 6
        controls.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -2 * Metrics.inset).isActive = true   // else the status wraps to no width
        controls.setContentHuggingPriority(.defaultHigh, for: .vertical)   // as tall as its views; the list takes the rest
        return bar
    }

    @objc private func showMore(_ sender: NSButton) {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Refresh"), action: #selector(reload), keyEquivalent: "").target = self
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}

/// No rows: the list gives way to a word in the middle of the panel, with the button that helps (show all, sign in).
extension TasksViewController {
    func addEmpty(to v: NSView) {
        for b in [showAll, setupButton] {
            b.bezelStyle = .push
            b.isHidden = true
        }
        emptyIcon.symbolConfiguration = .init(pointSize: 26, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .ui(13)
        emptyBox.setViews([emptyIcon, emptyLabel, showAll, setupButton], in: .center)
        emptyBox.orientation = .vertical
        emptyBox.spacing = 10
        emptyBox.isHidden = true
        emptyBox.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(emptyBox)
        NSLayoutConstraint.activate([emptyBox.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                                     emptyBox.centerYAnchor.constraint(equalTo: v.centerYAnchor, constant: -40),
                                     emptyBox.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -48),
                                     emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -48)])
    }

    /// `text` in the middle instead of the list; nil shows the list.
    func showEmpty(_ text: String?, symbol: String = "tray") {
        emptyBox.isHidden = text == nil
        split.isHidden = text != nil
        emptyLabel.stringValue = text ?? ""
        emptyIcon.image = .symbol(symbol, "")
    }
}

/// A label that takes no room while it says nothing.
final class StatusLine: NSTextField {
    override var stringValue: String { didSet { isHidden = stringValue.isEmpty } }
}
