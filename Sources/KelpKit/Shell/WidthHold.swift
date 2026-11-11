import AppKit

/// A view keeping the width it has while what holds it slides (a panel's column, the editor card): the constraint
/// pinning its `edge` to the holder lets go for a fixed width until `release()`. Laid out for every width on the way,
/// rows dropped their badges, lines rewrapped and terminals redrew, frame after frame.
@MainActor
struct WidthHold {
    private let inner: NSLayoutConstraint, width: NSLayoutConstraint

    /// nil when nothing pins that edge (the view isn't laid out in `holder`).
    init?(_ view: NSView, in holder: NSView, edge: NSLayoutConstraint.Attribute, width wide: CGFloat) {
        guard
            let inner = holder.constraints.first(where: {
                $0.firstItem === view && $0.secondItem === holder && $0.firstAttribute == edge
            })
        else { return nil }
        self.inner = inner
        width = view.widthAnchor.constraint(equalToConstant: wide)
        inner.isActive = false
        width.isActive = true
    }

    /// The edge pins the view again, unless it went elsewhere meanwhile (its floater, another workspace).
    func release() {
        width.isActive = false
        if let view = inner.firstItem as? NSView, view.superview === inner.secondItem as? NSView {
            inner.isActive = true
        }
    }
}
