import AppKit
import Testing

@testable import DesignKit
@testable import KelpKit

/// The panel capsule's chosen grey is one pill that moves to the next icon, on `Motion.base`.
@MainActor @Test func theChosenPanelsPillMovesToTheNextIcon() {
    let capsule = CapsuleStack(), first = NSButton(), second = NSButton()
    let window = onScreen(capsule)
    defer { offScreen(window) }
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
        defer { offScreen(window) }
        row.isSelected = true
        #expect(row.layer?.animation(forKey: kCATransition) != nil)   // a transition's key, whatever it was added as
    }
}

/// A project's row keeps its pill and its name where they are while the project folds or opens. The room under the row
/// (its card's end) changes at once and the row's height takes a third of a second to follow: on the way, the pill is
/// as tall as at rest and the name stands in the same place. A row arriving from nothing has no room for a pill yet.
@MainActor @Test func aProjectsPillKeepsItsHeightWhileTheProjectFolds() {
    let row: CGFloat = 28, ends = (top: SidebarRowView.pad, bottom: SidebarRowView.pad)
    let open = (top: ends.top, bottom: CGFloat(0)), folded = ends
    func pill(_ height: CGFloat, _ pads: (top: CGFloat, bottom: CGFloat), content: CGFloat = 28) -> NSRect {
        SidebarRowView.pill(
            in: NSRect(x: 0, y: 0, width: 240, height: height), pads: pads, card: SidebarRowView.cardBand,
            content: content)
    }
    let atRest = pill(row + ends.top, open)
    #expect(atRest.height == row - 4 && atRest.minY == ends.top + 2)
    #expect(pill(row + ends.top + ends.bottom, folded) == atRest)
    // On the way: the height between the two, with the pads of where it is going.
    for height in stride(from: row + ends.top, through: row + ends.top + ends.bottom, by: 1.5) {
        #expect(pill(height, folded) == atRest && pill(height, open) == atRest, "at \(height)")
        #expect(SidebarOutline.rest(in: height, pad: ends, rest: row) == row)
        #expect(SidebarOutline.rest(in: height, pad: (ends.top, 0), rest: row) == row)
    }
    #expect(pill(0.01 + ends.bottom, (0, ends.bottom), content: 0.01).height == 0)
    #expect(SidebarOutline.rest(in: 0.01 + ends.bottom, pad: (0, ends.bottom), rest: 0.01) == 0.01)
}

/// A done mark that's been read fades where it stood: a fade on its own layer, hidden at once, never showed.
@MainActor @Test func aReadDoneMarkFadesWhereItStood() {
    let parent = NSView(), mark = StatusMark()
    let window = onScreen(mark, in: parent)
    defer { offScreen(window) }
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
    defer { offScreen(window) }
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
    defer { offScreen(window) }
    let button = NSButton()
    capsule.addArrangedSubview(button)
    capsule.frame = NSRect(x: 0, y: 0, width: 60, height: 26)
    window.display()   // its layer comes from the parent's, as in a pane
    capsule.needsLayout = true
    capsule.layoutSubtreeIfNeeded()
    #expect(capsule.layer?.cornerRadius == 13)
    #expect(capsule.layer?.sublayers?.contains { $0.superlayer === capsule.layer && $0.delegate == nil } != true)
}

extension OneAtATime {
    /// A working agent keeps its ring when the Mac asks for less motion: the ring stands still, and no symbol takes its
    /// place (three dots in a circle are the "more" button).
    @Test func aWorkingMarkKeepsItsRingWithoutMotion() {
        let mark = StatusMark()
        let window = onScreen(mark, reduced: true)
        defer { offScreen(window) }
        mark.status = .working
        let ring = mark.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first {
            !$0.isHidden && $0.strokeEnd == 0.75
        }
        #expect(ring != nil)
        #expect(ring?.animationKeys()?.isEmpty ?? true)
        let symbols = mark.subviews.compactMap { $0 as? NSImageView }
        #expect(symbols.allSatisfy { $0.isHidden })
    }
}
