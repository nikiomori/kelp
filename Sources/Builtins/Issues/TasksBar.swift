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
            c.font = .ui(TextSize.row, weight: .medium)
            c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        filter.font = .ui(TextSize.row)
        // An inspector panel: its bar (what it lists, ↻), the last action's word under it, and the list over the
        // details.
        let controls = Bar.panel([source, filter], [refresh])
        status.isHidden = true
        let bar = NSStackView(views: [controls, status, failureBar])
        bar.orientation = .vertical
        bar.spacing = 6
        controls.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        failureBar.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
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
    /// A read that failed with no rows to keep: the error takes the list's place, with what sets it right (a tool to
    /// set up, a remote to add, Try Again).
    func showFailure(_ message: String, of src: Source) {
        showAll.isHidden = true
        rows = []
        lines = []
        listed = nil
        failureBar.show(nil)
        status.stringValue = ""
        // The source stays, because Linear and Jira need no remote.
        filter.isHidden = src.needsRemote && Forge.noRemote(message) != nil
        if src.needsRemote {
            showList(false)
            setup = emptyView.showForge(
                message, failed: String(localized: "Couldn't load the list"), hint: src.connectHint,
                setupButton: setupButton, checkAgain: checkAgain)
        } else {
            setup = nil
            setupButton.isHidden = true
            showEmpty(src.connectHint ?? message, symbol: "link")
        }
        table.reloadData()
        showDetail(nil)
    }

    /// Shows the rows a read brought. When they are the list already on show, a few that came or went move the others
    /// instead of jumping them.
    func show(_ rows: [Row], of src: Source, filter filterIndex: Int, picked: Int?) {
        let key = listKey(src, filterIndex)
        let places = listed == key ? table.rowPlaces(lineKey) : [:], old = Self.keys(self.rows)
        self.rows = rows
        lines = lined(rows)
        listed = key
        failureBar.show(nil)
        filter.isHidden = false
        // A list empty because of the filter isn't the same as empty, so say which and offer the way back.
        let narrowed = rows.isEmpty && filterIndex > 0 && src.none != nil
        status.stringValue = ""
        let chosen = filter.titleOfSelectedItem ?? ""
        let why = narrowed ? String(localized: "None in “\(chosen)”.") : src.none ?? String(localized: "Nothing here")
        showAll.isHidden = !narrowed
        setupButton.isHidden = true
        showEmpty(rows.isEmpty ? why : nil)
        let now = Self.keys(rows)
        table.reloadSettling(from: places, came: now.subtracting(old), gone: old.subtracting(now), lineKey) {
            table.reloadData()
            if picked != nil { reselect(picked) } else { showDetail(nil) }
        }
    }

    /// A line's name across a refresh: a pull request's or an issue's number, a heading's words. A tracker's task has
    /// none, and just shows.
    func lineKey(_ index: Int) -> String? {
        guard lines.indices.contains(index) else { return nil }
        switch lines[index] {
        case .heading(let text): return "heading \(text)"
        case .row(let row): return Self.number(row).map { "#\($0)" }
        }
    }
    static func keys(_ rows: [Row]) -> Set<String> { Set(rows.compactMap(number).map { "#\($0)" }) }

    /// Shows the spinner every panel waits with, as CI Runs does, when the list is on its way and there are no rows to
    /// keep showing.
    func showLoading() {
        showEmpty(nil)
        split.isHidden = true
        loadingView.show(String(localized: "Reading the list…"))
    }

    /// Shows the wait for a list on its way. The forge won't answer within the moment a quick answer takes, so with no
    /// rows to keep showing the wait shows at once. A refresh nobody asked for says nothing for the first second: the
    /// task that would say it is the one to cancel.
    func showWait(quietly: Bool) -> Task<Void, Never>? {
        if rows.isEmpty, !quietly {
            showLoading()
            return nil
        }
        return whileSlow { [weak self] in
            guard let self, rows.isEmpty else { return }
            showLoading()
        }
    }
}

/// A label that takes no room while it says nothing.
final class StatusLine: NSTextField {
    override var stringValue: String { didSet { isHidden = stringValue.isEmpty } }
}
