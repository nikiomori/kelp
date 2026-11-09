// A sidebar row under the pointer: the + and the badges stepping aside, the slot's action (✕ or the fold).
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension SidebarCell {
    /// The + comes in and the badges step aside (or out, where the name needs the room) in one movement: they jumped.
    /// The slot follows a moment later, and goes back at once. Reduce Motion: at once.
    func showHoverControls(_ on: Bool) {
        hovering = on
        showChanges()
        ciMark.spelled = on
        if on {
            reveal.after(Motion.settle) { [weak self] in self?.showAction() }
        } else {
            reveal.cancel()
            showAction()
        }
        guard let add else { return }
        // What comes in fades in where it stands: moved with the rest, it flew in from where it last was, over the badges.
        let coming = on && add.isHidden
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.fast)
            ctx.allowsImplicitAnimation = true
            add.isHidden = !on
            fitBadges()
            layoutSubtreeIfNeeded()
            guard coming else { return }
            add.layer?.removeAllAnimations()
            guard !Motion.reduced else { return }
            let fade = CABasicAnimation(keyPath: "opacity")   // faint while the badges are still moving out of its way
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Motion.fast
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            add.layer?.add(fade, forKey: "fadeIn")
        }
    }

    /// The slot: `view` at rest, the row's action over it. Tracks the pointer for both.
    func fillSlot(_ view: NSView) {
        rest = view
        slot.translatesAutoresizingMaskIntoConstraints = false
        for subview in [view, action] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                subview.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: 16), slot.heightAnchor.constraint(equalToConstant: 16),
            action.widthAnchor.constraint(equalToConstant: 16), action.heightAnchor.constraint(equalToConstant: 16)
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    func acted() {
        if case .agent(let id) = node.kind { app.workbench.closeChat(session: id) } else { owner?.toggle(node) }
    }

    /// The action in the slot under the pointer: a row with nothing to fold keeps what it has.
    func showAction() {
        var on = hovering && owner?.renaming == nil
        if case .agent = node.kind {
        } else {
            on = on && !node.children.isEmpty
            showFold()
        }
        guard action.isHidden == on else { return }
        slot.crossfade()
        action.isHidden = !on
        // Faded, not hidden: whether it shows is its own (a read agent's mark hides itself), and unhiding brought back a ✓.
        rest?.alphaValue = on ? 0 : 1
    }

    /// The chevron turns as the row folds.
    func showFold() {
        let folded = owner?.isCollapsed(node) ?? false
        action.image = .symbol(
            folded ? "chevron.right" : "chevron.down",
            folded ? String(localized: "Expand") : String(localized: "Collapse"))
        action.toolTip = action.image?.accessibilityDescription
        if let was = shownFolded, was != folded, !action.isHidden { action.turn(from: folded ? -.pi / 2 : .pi / 2) }
        shownFolded = folded
    }

    /// The pointer is on the slot's action: the row's card waits, the row's fate is being decided. `point` is in the window.
    func overAction(_ point: NSPoint) -> Bool { !action.isHidden && actionArea.contains(convert(point, from: nil)) }
    /// A little wider than what's drawn, from the pill's edge to the name, and as high as the pill.
    var actionArea: NSRect { action.convert(action.bounds, to: self).insetBy(dx: -3, dy: -4) }
}
