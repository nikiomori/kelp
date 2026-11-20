import AppKit
import SwiftUI

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
        guard isHidden != (error == nil) else { return }
        crossfade()
        // The rows under it slide down to make room and back up when it goes (in two thirds of the time), instead of
        // jumping a line at once.
        let host = window?.contentView
        host?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = host == nil ? 0 : Motion.duration(error == nil ? Motion.fast : Motion.base)
            ctx.timingFunction = CAMediaTimingFunction(name: error == nil ? .easeIn : .easeOut)
            ctx.allowsImplicitAnimation = true
            isHidden = error == nil
            host?.layoutSubtreeIfNeeded()
        }
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

/// `FailureBar` for a SwiftUI page: the same grey line over what was read before, saying the refresh failed, with Try
/// Again on the bar's plate. It fades in and out; the page animates its `failed` value so what is below moves with it.
public struct FailureLine: View {
    private let error: String
    private let retry: () -> Void
    public init(_ error: String, retry: @escaping () -> Void) {
        self.error = error
        self.retry = retry
    }
    public var body: some View {
        HStack(spacing: Metrics.gap) {
            Image(systemName: "exclamationmark.triangle").font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Couldn’t refresh"))
            Text(String(localized: "Couldn’t refresh: \(error)")).font(.ui(TextSize.caption)).foregroundStyle(
                .secondary
            )
            .lineLimit(1).truncationMode(.tail).help(error)
            Spacer(minLength: Metrics.gap)
            Button(String(localized: "Try Again"), action: retry).buttonStyle(BarButtonStyle())
        }
        .transition(.opacity)
    }
}
