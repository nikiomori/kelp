import AppKit

/// A line over a list that couldn't be read again: what went wrong, and Try Again. The rows read before stay under it,
/// so a failed refresh takes nothing off the screen. A panel with nothing to keep says the error in the list's place
/// instead (`EmptyStateView.showError`). Hidden, the bar takes no room in a stack view.
@MainActor
public final class FailureBar: NSStackView {
    private let line = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)

    public init(retry: @escaping () -> Void) {
        super.init(frame: .zero)
        let mark = NSImageView(image: .symbol("exclamationmark.triangle", String(localized: "Couldn’t refresh")))
        mark.symbolConfiguration = .chrome(Metrics.iconSmall)
        mark.contentTintColor = .secondaryLabelColor   // a state at the edge, which calls nobody: no colour
        let again = TextButton(String(localized: "Try Again"), onClick: retry)
        again.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A long error is cut at its end, and read whole in the tooltip: it doesn't widen the panel.
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setViews([mark, line, NSView(), again], in: .leading)
        spacing = Metrics.gap
        edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The error on show, nil while the bar is away.
    public var shown: String? { isHidden ? nil : line.toolTip }

    /// Says why the list couldn't be read again. nil takes the bar away.
    public func show(_ error: String?) {
        line.stringValue = error.map { String(localized: "Couldn’t refresh: \($0)") } ?? ""
        line.toolTip = error
        if isHidden != (error == nil) { crossfade() }
        isHidden = error == nil
    }

    /// The bar under a panel's header, as one view to lay out where the header was.
    public func under(_ header: NSView) -> NSView {
        let column = NSStackView(views: [header, self])
        column.orientation = .vertical
        column.spacing = 0
        // As tall as what it holds, over a list that would give it the room: stretched, it pushed the panel's empty
        // state to the bottom, which stands under it.
        column.setHuggingPriority(.defaultHigh, for: .vertical)
        for view in [header, self] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }
}
