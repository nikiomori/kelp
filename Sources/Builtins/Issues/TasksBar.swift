import AppKit
import DesignKit
import KelpKit

/// The panel's bar: what it lists (source and filter as title words) and Refresh, the last action's word under it.
extension TasksViewController {
    func makeBar() -> NSView {
        let refresh = IconButton(
            .symbol("arrow.clockwise"), tip: String(localized: "Refresh"), target: self, action: #selector(reload))
        status.textColor = .secondaryLabelColor
        status.font = .ui(TextSize.caption)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Popups that read as the panel's title words, not as two buttons the width of the panel.
        for c in [source, filter] {
            c.controlSize = .small
            c.isBordered = false
            c.font = .ui(TextSize.row, weight: .semibold)
            c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        filter.font = .ui(TextSize.row)
        // An inspector panel: its bar (what it lists, ↻), the last action's word under it, the list over the details.
        let controls = Bar.panel([source, filter], [refresh])
        status.isHidden = true
        let bar = NSStackView(views: [controls, status])
        bar.orientation = .vertical
        bar.spacing = 6
        controls.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -2 * Metrics.inset).isActive = true   // else the status wraps to no width
        bar.setHuggingPriority(.defaultHigh, for: .vertical)   // as tall as its views: over the split's holding, or the list gets no height
        return bar
    }
}

/// No rows: the list gives way to the empty state, with the button that helps (show all, sign in).
extension TasksViewController {
    /// `text` instead of the list, with the buttons that aren't hidden; nil shows the list.
    func showEmpty(_ text: String?, symbol: String = "tray") {
        showList(text == nil)
        emptyView.show(text, symbol: symbol, buttons: [showAll, setupButton].filter { !$0.isHidden })
    }

    /// The list, or room for the empty state in its place.
    func showList(_ on: Bool) {
        loadingView.show(nil)
        split.isHidden = !on
        placeDivider()
    }
}

extension TasksViewController {
    /// The list is on its way and there are no rows to keep showing: the spinner every panel waits with, as CI Runs.
    func showLoading() {
        showEmpty(nil)
        split.isHidden = true
        loadingView.show(String(localized: "Loading…"))
    }
}

/// A label that takes no room while it says nothing.
final class StatusLine: NSTextField {
    override var stringValue: String { didSet { isHidden = stringValue.isEmpty } }
}
