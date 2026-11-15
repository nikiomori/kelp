import AppKit
import Testing

@testable import DesignKit
@testable import KelpKit

/// The panel capsule's chosen grey is one pill that moves to the next icon, on `Motion.base`.
@MainActor @Test func theChosenPanelsPillMovesToTheNextIcon() {
    let capsule = CapsuleStack(), first = NSButton(), second = NSButton()
    let window = onScreen(capsule)
    defer { withExtendedLifetime(window) {} }
    capsule.frame = NSRect(x: 0, y: 0, width: 100, height: 26)
    for button in [first, second] {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        capsule.addArrangedSubview(button)
    }
    capsule.chosen = first
    capsule.layoutSubtreeIfNeeded()
    let pill = capsule.layer?.sublayers?.first
    #expect(pill?.frame == first.frame)
    capsule.chosen = second
    #expect(pill?.frame == second.frame)
    #expect(pill?.animation(forKey: "position")?.duration == Motion.base)
}

/// A sidebar row's pill and a list's selection fade in and out instead of switching.
@MainActor @Test func aSelectionFadesFromRowToRow() {
    for row in [SidebarRowView(frame: .zero), ListRowView()] as [NSTableRowView] {
        let window = onScreen(row)
        defer { withExtendedLifetime(window) {} }
        row.isSelected = true
        #expect(row.layer?.animation(forKey: kCATransition) != nil)   // a transition's key, whatever it was added as
    }
}
