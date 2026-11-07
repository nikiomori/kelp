import AppKit

extension NSLayoutConstraint {
    /// The constraint at `priority`, for a list of them in `activate`.
    func withPriority(_ priority: Float) -> NSLayoutConstraint {
        self.priority = .init(priority)
        return self
    }
}

extension NSView {
    /// Adds `v` filling this view, `inset` in from its edges.
    package func pin(_ v: NSView, inset: NSEdgeInsets = NSEdgeInsetsZero) {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right)
        ])
    }
}

/// A scroll view's document that starts at the top.
package final class FlippedView: NSView { package override var isFlipped: Bool { true } }

/// `views` top to bottom, each the full width; the one without a height of its own takes the rest (a body under or
/// over a bar). Used by every mode view.
@MainActor
package func stacked(_ views: NSView...) -> NSView {
    let v = NSView()
    var above = v.topAnchor
    for x in views {
        x.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(x)
        NSLayoutConstraint.activate([
            x.topAnchor.constraint(equalTo: above), x.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            x.trailingAnchor.constraint(equalTo: v.trailingAnchor)
        ])
        above = x.bottomAnchor
    }
    above.constraint(equalTo: v.bottomAnchor).isActive = true
    return v
}
