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

/// A done mark that's been read fades where it stood: a fade on its own layer, hidden at once, never showed.
@MainActor @Test func aReadDoneMarkFadesWhereItStood() {
    let parent = NSView(), mark = StatusMark()
    let window = onScreen(mark, in: parent)
    defer { withExtendedLifetime(window) {} }
    mark.status = .done
    #expect(!mark.isHidden)
    mark.unread = false
    #expect(mark.isHidden)
    let ghost = parent.subviews.first { $0 !== mark }
    #expect(ghost != nil)
    #expect(ghost?.alphaValue ?? 1 < 1 || ghost?.layer?.animationKeys()?.isEmpty == false)
}

/// The context ring fills on the scale (`Motion.base`), not on a bare layer's quarter second.
@MainActor @Test func theContextRingFillsOnTheScale() {
    let meter = ContextMeter()
    let window = onScreen(meter)
    defer { withExtendedLifetime(window) {} }
    meter.usage = .init(used: 120_000, window: 200_000)
    meter.usage = .init(used: 160_000, window: 200_000)
    let fill = meter.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.last
    #expect(fill?.strokeEnd == 0.8)
    #expect(fill?.animation(forKey: "strokeEnd")?.duration == Motion.base)
}

/// A pane's capsule (its agent and "+" buttons) keeps its round ends: nothing chosen, no pill, its layer left alone.
@MainActor @Test func aCapsuleWithNothingChosenKeepsItsRoundEnds() {
    let parent = NSView(), capsule = CapsuleStack()
    parent.wantsLayer = true
    let window = onScreen(capsule, in: parent)
    defer { withExtendedLifetime(window) {} }
    let button = NSButton()
    capsule.addArrangedSubview(button)
    capsule.frame = NSRect(x: 0, y: 0, width: 60, height: 26)
    window.display()   // its layer comes from the parent's, as in a pane
    capsule.needsLayout = true
    capsule.layoutSubtreeIfNeeded()
    #expect(capsule.layer?.cornerRadius == 13)
    #expect(capsule.layer?.sublayers?.contains { $0.superlayer === capsule.layer && $0.delegate == nil } != true)
}
