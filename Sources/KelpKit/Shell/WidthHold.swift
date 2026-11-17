import AppKit

/// Keeps a view at the width it has while its holder slides (a panel's column, the editor card). The constraint that
/// pins the view's `edge` to the holder gives way to a fixed width until `release()`. When the view was laid out for
/// every width on the way, rows dropped their badges, lines rewrapped and terminals redrew, frame after frame.
@MainActor
struct WidthHold {
    private let inner: NSLayoutConstraint, width: NSLayoutConstraint

    /// Returns nil when nothing pins that edge (the view isn't laid out in `holder`).
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

    /// Pins the view's edge again, unless the view went elsewhere meanwhile (its floater, another workspace).
    func release() {
        width.isActive = false
        if let view = inner.firstItem as? NSView, view.superview === inner.secondItem as? NSView {
            inner.isActive = true
        }
    }
}
