// A sidebar row under the pointer: the + and the badges stepping aside, the slot's action (✕ or the fold).
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension SidebarCell {
    /// Brings in the + while the badges step aside (or out, where the name needs the room) in one movement, because
    /// separately they jumped. The slot follows a moment later, and goes back at once. Under Reduce Motion it all
    /// happens at once. The badges keep their dots, and each spells out its words only under the pointer itself
    /// (`spell`), so the row doesn't grow as the pointer passes over it.
    func showHoverControls(_ on: Bool) {
        hovering = on
        if on {
            reveal.after(Motion.settle) { [weak self] in self?.showAction() }
        } else {
            reveal.cancel()
            showAction()
        }
        guard let add else { return }
        // The + fades in where it stands. When it moved with the rest, it flew in from where it last was, over the
        // badges.
        let coming = on && add.isHidden
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.fast)
            ctx.allowsImplicitAnimation = true
            add.isHidden = !on
            cover(on)
            fitBadges()
            layoutSubtreeIfNeeded()
            guard coming else { return }
            add.layer?.removeAllAnimations()
            guard !Motion.reduced else { return }
            let fade = CABasicAnimation(keyPath: "opacity")   // faint while the badges still move out of the +'s way
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Motion.fast
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            add.layer?.add(fade, forKey: "fadeIn")
        }
    }

    /// Spells out a git mark under the pointer: the changes dot shows its counts, and a failed CI's dot shows "CI". The
    /// mark stays while the pointer is on it, whatever room the name needs, because if hidden it would go out from
    /// under the pointer and come back.
    func spell(_ badge: NSView?, _ on: Bool) {
        if on, badge === covered { return }   // under the +, it doesn't spell its words out from under it
        if on { spelling = badge } else if spelling === badge { spelling = nil }
        if badge === pr { updateBadges() } else { showChanges() }
        ciMark.spelled = spelling === ci
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.fast)
            ctx.allowsImplicitAnimation = true
            fitBadges()
            layoutSubtreeIfNeeded()
        }
    }

    /// Puts a project's + over the row's end, its glyph on the row's edge, where the last mark ends. It stands over the
    /// marks instead of beside them, so they keep their places when it comes.
    func overlay(_ button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        guard let row = changes.superview else { return }
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
    }

    /// While the + shows, the mark it stands over fades out, and a row that ends in words (its name) ends them short of
    /// the +.
    func cover(_ on: Bool) {
        guard let row = changes.superview as? NSStackView, let add else { return }
        covered?.alphaValue = 1
        covered = nil
        row.edgeInsets.right = 0
        guard on else { return }
        let last = row.arrangedSubviews.last { !$0.isHidden && row.visibilityPriority(for: $0) != .notVisible }
        if let last, [changes, pr, ci, stack].contains(where: { $0 === last }) {
            covered = last
            last.alphaValue = 0
        } else {
            row.edgeInsets.right = add.intrinsicContentSize.width + row.spacing
        }
    }

    /// Fills the slot with `view` at rest, and the row's action over it under the pointer. The slot tracks the pointer
    /// for both.
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

    /// Shows the action in the slot under the pointer. A row with nothing to fold keeps what it shows.
    func showAction() {
        var on = hovering && owner?.renaming == nil
        if case .agent = node.kind {
        } else {
            // A folded project has no rows under it when its chats are all on one screen, and still opens.
            let folded: Bool = if case .project = node.kind { owner?.isCollapsed(node) == true } else { false }
            on = on && (!node.children.isEmpty || folded)
            showFold()
        }
        guard action.isHidden == on else { return }
        slot.crossfade()
        action.isHidden = !on
        // Fade the rest view, not hide it, because the view decides on its own whether it shows (a read agent's mark
        // hides itself), and unhiding it brought back a ✓.
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

    /// Returns whether `point` is on the slot's action. The row's card then waits, since the user is deciding what to
    /// do with the row. `point` is in window coordinates.
    func overAction(_ point: NSPoint) -> Bool { !action.isHidden && actionArea.contains(convert(point, from: nil)) }
    /// The area the action answers in. It is a little wider than what's drawn, from the pill's edge to the name, and as
    /// high as the pill.
    var actionArea: NSRect { action.convert(action.bounds, to: self).insetBy(dx: -3, dy: -4) }
}
