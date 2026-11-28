// What an editor area reports and keeps: the focused tab, its dividers, and its tabs for the palette and ui.state.
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension EditorArea {
    // MARK: focus

    func responderChanged(_ responder: NSResponder?) {
        var candidate = responder as? NSView
        while let current = candidate, !(current is GroupView) { candidate = current.superview }
        guard let group = candidate as? GroupView, layout.focused != group.groupId else { return }
        let old = layout.focused
        layout.focused = group.groupId
        if let old { refreshGroup(old) }
        refreshGroup(group.groupId)
    }

    func focusSelected() {
        guard let tab = layout.focusedGroup?.selectedTab else {
            start?.focus()
            return
        }
        DispatchQueue.main.async { [weak self] in self?.contents[tab.id]?.focus() }
    }

    /// After a switch brought the area into the card, it settles there: the tab strips first, then the panes one after
    /// another in reading order, `Motion.switchStagger` apart (the empty workspace's page as the one pane).
    func settleIn() {
        view.layoutSubtreeIfNeeded()   // an area shown for the first time has no size yet
        let groups = (layout.root?.sessions ?? []).compactMap { groupViews[$0] }
        for (index, group) in groups.enumerated() { group.settle(after: Double(index + 1) * Motion.switchStagger) }
        start?.settleIn(after: Motion.switchStagger)
    }

    /// Every open tab (URI and title), for the palette.
    var openTabs: [(String, String)] {
        layout.allTabs.map { ($0.uri, contents[$0.id]?.title ?? placeholder($0).title) }
    }

    /// Open tabs and focus, for `ui.state`.
    var stateForAgents: ShownUI.Editor {
        ShownUI.Editor(
            tabs: layout.allTabs.map { ShownUI.Item(uri: $0.uri, title: contents[$0.id]?.title ?? "") },
            focused: layout.focusedGroup?.selectedTab?.uri ?? "")
    }
}

extension EditorArea: NSSplitViewDelegate {
    /// A dragged divider stays where it was put: tab changes and relaunches rebuild the splits from these shares.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let sv = notification.object as? NSSplitView, sv.window != nil, let key = sv.identifier?.rawValue,
            sv.arrangedSubviews.count == key.split(separator: ",").count
        else { return }   // the split view is being taken apart, not resized by the user
        let lengths = sv.arrangedSubviews.map { Double(sv.isVertical ? $0.frame.width : $0.frame.height) }
        let total = lengths.reduce(0, +)
        guard total > 20 else { return }
        let shares = lengths.map { $0 / total }
        if layout.sizes?[key].map({ zip($0, shares).allSatisfy { abs($0 - $1) < 0.002 } }) == true { return }
        layout.sizes = (layout.sizes ?? [:]).merging([key: shares]) { $1 }
    }
}
