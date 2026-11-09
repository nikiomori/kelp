import AppKit

extension NSLayoutConstraint {
    /// The constraint at `priority`, for a list of them in `activate`.
    public func withPriority(_ priority: Float) -> NSLayoutConstraint {
        self.priority = .init(priority)
        return self
    }
}

extension NSView {
    /// Adds `v` filling this view, `inset` in from its edges.
    public func pin(_ view: NSView, inset: NSEdgeInsets = NSEdgeInsetsZero) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right)
        ])
    }
}

/// A scroll view's document that starts at the top.
public final class FlippedView: NSView { public override var isFlipped: Bool { true } }

/// `views` top to bottom, each the full width; the one without a height of its own takes the rest (a body under or
/// over a bar). Used by every mode view.
@MainActor
public func stacked(_ views: NSView...) -> NSView {
    let column = NSView()
    var above = column.topAnchor
    for view in views {
        view.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: above), view.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: column.trailingAnchor)
        ])
        above = view.bottomAnchor
    }
    above.constraint(equalTo: column.bottomAnchor).isActive = true
    return column
}
