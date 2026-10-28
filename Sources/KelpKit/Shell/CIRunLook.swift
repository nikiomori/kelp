import AppKit
import Core
import DesignKit

/// How a CI run reads, in CI Runs (Issues) and on the Source Control panel (Git).
@MainActor
package enum CIRunLook {
    /// ✓ green, ✕ red, the agents' spinning ring while it runs, an empty circle while it waits its turn,
    /// – grey when skipped or cancelled.
    package static func mark(_ status: String, _ conclusion: String?) -> NSView {
        let words = Self.words(status, conclusion)
        if status == "in_progress" {
            let m = StatusMark(size: 12)   // as tall as the symbols beside it
            m.status = .working
            m.toolTip = words
            return m
        }
        let (symbol, color): (String, NSColor) = switch (status, conclusion) {
        case ("completed", "success"?): ("checkmark.circle.fill", .systemGreen)
        case ("completed", "skipped"?), ("completed", "cancelled"?), ("completed", "neutral"?): ("minus.circle", .tertiaryLabelColor)
        case ("completed", _): ("xmark.circle.fill", .systemRed)
        default: ("circle", .tertiaryLabelColor)
        }
        let v = NSImageView(image: .symbol(symbol, words))
        v.contentTintColor = color
        v.toolTip = words
        v.symbolConfiguration = .init(pointSize: 12, weight: Metrics.iconWeight)
        return v
    }

    package static func words(_ status: String, _ conclusion: String?) -> String {
        switch (status, conclusion) {
        case ("completed", "success"?): String(localized: "Succeeded")
        case ("completed", "skipped"?): String(localized: "Skipped")
        case ("completed", "cancelled"?): String(localized: "Cancelled")
        case ("completed", "neutral"?): String(localized: "Neutral")
        case ("completed", _): String(localized: "Failed")
        case ("in_progress", _): String(localized: "Running")
        case ("waiting", _): String(localized: "Waiting for approval")
        default: String(localized: "Queued")
        }
    }

    /// A branch's CI in one word, for tooltips and VoiceOver.
    static func words(_ s: CIRuns.State) -> String {
        switch s {
        case .passed: String(localized: "Succeeded")
        case .running: String(localized: "Running")
        case .waiting: String(localized: "Waiting for approval")
        case .failed: String(localized: "Failed")
        }
    }

    package static func ago(_ iso: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d else { return "" }
        return shortAgo(d)   // "4m", "2h": one way to say when, as the graph and the sidebar do (it read "1d ago" here)
    }
}

/// A branch's CI in one mark, drawn as agents' states are: the spinning ring while it runs, the orange ◎ while a deploy waits
/// for someone's approval, the quiet filled ✓ when it passed and you haven't looked, and CI Runs' red ✕ when it failed.
/// It sits over a chip's or badge's image slot and lets the click through to it.
@MainActor
final class CIMark: NSView {
    private let agentLike = StatusMark(size: 12), failed = NSImageView()
    var state: CIRuns.State? { didSet { if state != oldValue { update() } } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        agentLike.announces = false   // its words are an agent's; the chip or badge says the CI's
        failed.image = .symbol("xmark.circle.fill", "")
        failed.symbolConfiguration = .init(pointSize: 11, weight: Metrics.iconWeight)
        failed.contentTintColor = .systemRed
        for v in [agentLike, failed] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v)
            NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: centerXAnchor), v.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    private func update() {
        isHidden = state == nil
        failed.isHidden = state != .failed
        agentLike.status = switch state {
        case .running: .working
        case .waiting: .waiting
        case .passed: .done
        case .failed, nil: nil
        }
    }

    /// An empty image: holds the mark's place in a button's title or image slot.
    static func room(_ side: CGFloat) -> NSImage { NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in true } }
}
