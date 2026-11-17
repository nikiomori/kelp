import AppKit
import DesignKit
import KelpKit

/// The panel's bar: what it lists (source and filter as title words) and Refresh, with the last action's word under
/// it.
extension TasksViewController {
    func makeBar() -> NSView {
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
        // An inspector panel: its bar (what it lists, ↻), the last action's word under it, and the list over the
        // details.
        let controls = Bar.panel([source, filter], [refresh])
        status.isHidden = true
        let bar = NSStackView(views: [controls, status])
        bar.orientation = .vertical
        bar.spacing = 6
        controls.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        // Without this width, the status wraps to no width.
        status.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -2 * Metrics.inset).isActive = true
        // As tall as its views, over the split's holding, or the list gets no height.
        bar.setHuggingPriority(.defaultHigh, for: .vertical)
        return bar
    }
}

/// With no rows, the list gives way to the empty state, with the button that helps (show all, sign in).
extension TasksViewController {
    /// Shows `text` instead of the list, with the buttons that aren't hidden; nil shows the list.
    func showEmpty(_ text: String?, symbol: String = "tray") {
        showList(text == nil)
        emptyView.show(text, symbol: symbol, buttons: [showAll, setupButton].filter { !$0.isHidden })
    }

    /// Shows the list, or makes room for the empty state in its place.
    func showList(_ on: Bool) {
        loadingView.show(nil)
        // The rows fade in over what stood in their place (the loading rows fading away).
        if on, split.isHidden { split.fadeIn() } else { split.isHidden = !on }
        placeDivider()
    }
}

extension TasksViewController {
    /// Shows the spinner every panel waits with, as CI Runs does, when the list is on its way and there are no rows to
    /// keep showing.
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
