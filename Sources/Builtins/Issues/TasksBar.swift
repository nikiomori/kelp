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

/// No rows: the list gives way to the empty state, with the button that helps (show all, sign in).
extension TasksViewController {
    /// `text` instead of the list (an error with `error`), with the buttons that aren't hidden; nil shows the list.
    func showEmpty(_ text: String?, symbol: String = "tray", error: String? = nil, title: String? = nil) {
        split.isHidden = text != nil
        let buttons = [showAll, setupButton].filter { !$0.isHidden }
        if let error { emptyView.showError(error, text: text, buttons: buttons) }
        else if let title { emptyView.show(title, symbol: symbol, text: text, buttons: buttons) }
        else { emptyView.show(text, symbol: symbol, buttons: buttons) }
    }
}

/// A label that takes no room while it says nothing.
final class StatusLine: NSTextField {
    override var stringValue: String { didSet { isHidden = stringValue.isEmpty } }
}
