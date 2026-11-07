import AppKit
import SwiftUI

/// What a panel, a tab or a window shows while what it lists is on its way: a small spinner and one secondary line
/// beside it, where `EmptyStateView` stands and lifted as it is, so one gives way to the other without a jump.
@MainActor
public final class LoadingView: NSView {
    private let spinner = NSProgressIndicator()
    private let line = NSTextField(labelWithString: "")

    public init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        line.font = .ui(13)
        line.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [spinner, line])
        stack.spacing = Metrics.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let lifted = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Metrics.emptyLift)
        lifted.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), lifted,
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Metrics.inset)
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows it with `text` ("Loading…"); nil hides it and stops the spinner.
    public func show(_ text: String?) {
        isHidden = text == nil
        line.stringValue = text ?? ""
        if text == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }

    /// Fills `area` under `top`, as an empty state does.
    public func place(in area: NSView, under top: NSView? = nil) { pin(in: area, under: top) }

    /// Clicks go through to what's under it.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The same for SwiftUI: the spinner and its line, as a form's row or, with `.frame(maxHeight: .infinity)`, a page's middle.
public struct LoadingLine: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        HStack(spacing: Metrics.gap) {
            ProgressView().controlSize(.small)
            Text(text).font(.ui(13)).foregroundStyle(.secondary)
        }
    }
}

extension NSView {
    /// Fills `area` under `top` (its bar), over whatever the area shows.
    func pin(in area: NSView, under top: NSView?) {
        translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: top?.bottomAnchor ?? area.topAnchor),
            bottomAnchor.constraint(equalTo: area.bottomAnchor),
            leadingAnchor.constraint(equalTo: area.leadingAnchor),
            trailingAnchor.constraint(equalTo: area.trailingAnchor)
        ])
    }
}
