import AppKit
import Core
import DesignKit

extension SidebarCell {
    /// An empty group's row while it waits to close by itself (Settings › Appearance › Close empty groups): its name is
    /// grey, and in the last eighth of its time (3 hours of a day) an hourglass says what is left. When the time is up,
    /// the sand runs out, and then the row goes (`ranOut`, `SidebarController.leaveGhosts`).
    func showCountdown(_ group: Worktree) {
        let actions = WorkspaceActions(app), closes = actions.closesAt(group)
        let left = closes?.timeIntervalSinceNow ?? 0
        // Due counts as run out too: the row may be re-read between its closing and its going.
        let out = app.workbench.timeUp.contains(group.id) || closes != nil && left <= 0
        if closes != nil, !selected { title.textColor = .secondaryLabelColor }
        let near = out || closes != nil && left <= (actions.emptyFor ?? 0) / 8
        hourglass.isHidden = !near
        guard near else { return }
        let name = out ? "hourglass.bottomhalf.filled" : "hourglass.tophalf.filled"
        let words =
            out ? String(localized: "Closing") : String(localized: "Empty: closes by itself in \(shortSpan(left))")
        if sand != name {
            let image = NSImage.symbol(name, words)
            if sand == nil {
                hourglass.image = image
            } else {
                hourglass.setSymbolImage(image, contentTransition: .replace)
            }
            sand = name
        }
        hourglass.toolTip = words
        trailing.stringValue = out ? "" : shortSpan(max(left, 60))
    }

    /// True once the row's sand ran out: it goes slowly, as something that was due, not as a row that vanished.
    var ranOut: Bool { sand == "hourglass.bottomhalf.filled" }
}
