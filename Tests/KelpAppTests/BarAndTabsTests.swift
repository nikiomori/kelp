import AppKit
import Core
import DesignKit
import Testing

@testable import BuiltinRun
@testable import KelpKit

@MainActor private func find<Part: NSView>(_ type: Part.Type, in view: NSView) -> Part? {
    (view as? Part) ?? view.subviews.compactMap { find(type, in: $0) }.first
}

extension OneAtATime {
    /// A tab's slot shows a paused agent's moon, as its sidebar row does, and the tab is no louder for it: in a pane
    /// without focus it fades with the others, where one that asks stays bright. VoiceOver hears the state after the
    /// title, and that a file has unsaved changes.
    @Test func aTabSaysPausedAndEditedWithoutGettingLouder() throws {
        Motion.pinned = true   // the fade is over at once
        defer { Motion.pinned = nil }
        let tab = TabButton()
        tab.stripDimmed = true
        let mark = try #require(find(StatusMark.self, in: tab)), row = try #require(find(NSStackView.self, in: tab))
        let cases: [(status: AgentStatus?, edited: Bool, marked: Bool, bright: Bool, said: String)] = [
            (.paused, false, true, false, "One, Paused"),
            (.waiting, false, true, true, "One, Needs your input"),
            (.idle, false, false, false, "One, Ready"),
            (nil, true, false, false, "One, Edited"),
            (nil, false, false, false, "One")
        ]
        for item in cases {
            let badge = item.status.map { TabBadge(status: $0) }
            tab.set(
                TabStrip.Item(id: "a", title: "One", toolTip: nil, edited: item.edited, badge: badge), selected: false,
                groupFocused: false)
            #expect((mark.alphaValue == 1 && !mark.isHidden) == item.marked, "\(item.said)")
            #expect((row.alphaValue == 1) == item.bright, "\(item.said)")
            #expect(tab.accessibilityLabel() == item.said)
        }
    }
}

extension OneAtATime {
    /// The tabs' row grows with Settings › Appearance › Text size, a strip already built too, and is as it was for normal
    /// text. A capsule in the window bar grows as well, but leaves 2 pt of the title bar above it and below it.
    @Test func theTabsAndTheBarsCapsulesGrowWithTheText() {
        defer { TextSize.apply(nil) }
        let strip = TabStrip()
        strip.set([TabStrip.Item(id: "a", title: "One", toolTip: nil)], selected: "a")
        func heights(_ row: TabStrip) -> [CGFloat] { [row.fittingSize.height, row.buttons[0].fittingSize.height] }
        #expect(heights(strip) == [40, 28] && ChipCapsule().fittingSize.height == 22)
        strip.low = true
        #expect(heights(strip) == [32, 24])
        strip.low = false
        for size in ["large", "larger"] {
            TextSize.apply(size)
            strip.restyle()   // as the editor area does when the setting changes
            let grown = heights(strip), fresh = TabStrip()
            fresh.set([TabStrip.Item(id: "a", title: "One", toolTip: nil)], selected: "a")
            #expect(grown[0] > 40 && grown[1] > 28 && grown == heights(fresh), "\(size)")
            let capsule = ChipCapsule().fittingSize.height
            #expect(capsule > 22 && capsule <= WindowBar.height - 4, "\(size)")
        }
        TextSize.apply(nil)
        strip.restyle()
        #expect(heights(strip) == [40, 28])
    }
}
