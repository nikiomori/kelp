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
        let empty = EmptyStateView()
        empty.show(
            String(localized: "Extension Turned Off"), symbol: "puzzlepiece.extension",
            text: String(localized: "The extension that shows “\(uri)” is turned off or was removed."),
            buttons: [
                ClosureButton(title: String(localized: "Extensions…")) {
                    SettingsWindow.show(app, section: "extensions")
                }
            ])
        view = empty
    }
    func focus() {}
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
