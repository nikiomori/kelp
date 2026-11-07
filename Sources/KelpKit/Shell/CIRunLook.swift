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
            let ring = StatusMark(size: 12)   // as tall as the symbols beside it
            ring.status = .working
            ring.toolTip = words
            return ring
        }
        let (symbol, color): (String, NSColor) =
            switch (status, conclusion) {
            case ("completed", "success"?): ("checkmark.circle.fill", .systemGreen)
            case ("completed", "skipped"?), ("completed", "cancelled"?), ("completed", "neutral"?):
                ("minus.circle", .tertiaryLabelColor)
            case ("completed", _): ("xmark.circle.fill", .systemRed)
            default: ("circle", .tertiaryLabelColor)
            }
        let view = NSImageView(image: .symbol(symbol, words))
        view.contentTintColor = color
        view.toolTip = words
        view.symbolConfiguration = .chrome()
        return view
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
    static func words(_ state: CIRuns.State) -> String {
        switch state {
        case .passed: String(localized: "Succeeded")
        case .running: String(localized: "Running")
        case .waiting: String(localized: "Waiting for approval")
        case .failed: String(localized: "Failed")
        }
    }

    package static func ago(_ iso: String) -> String {
        guard let date = CIRuns.date(iso) else { return "" }
        // "4m", "2h": one way to say when, as the graph and the sidebar do (it read "1d ago" here)
        return shortAgo(date)
    }
}

/// A branch's CI in one mark, drawn as agents' states are: the spinning ring while it runs, the orange ◎ while a deploy waits
/// for someone's approval, the quiet filled ✓ when it passed and you haven't looked, and a red dot when it failed (CI Runs'
/// filled ✕ was the loudest thing in the sidebar and read as a window's close button); `spelled`, it says "CI" instead.
/// It sits over a chip's or badge's image slot and lets the click through to it.
@MainActor
final class CIMark: NSView {
    private let agentLike = StatusMark(size: 12), word = NSTextField(labelWithString: "CI")
    var state: CIRuns.State? { didSet { if state != oldValue { update() } } }
    /// Under the pointer (a sidebar row): a failure says "CI" where its dot was, as the changes dot shows its counts.
    var spelled = false { didSet { if spelled != oldValue { update() } } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        agentLike.announces = false   // its words are an agent's; the chip or badge says the CI's
        word.font = .ui(11, weight: .semibold)
        word.textColor = .textRed
        for part in [agentLike, word] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
            NSLayoutConstraint.activate([
                part.centerXAnchor.constraint(equalTo: centerXAnchor),
                part.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// How much wider than its 12 pt the mark is while it says "CI": the room a row must keep for it.
    var overhang: CGFloat { spelled && state == .failed ? max(0, ceil(word.intrinsicContentSize.width) - 12) : 0 }

    private func update() {
        isHidden = state == nil
        word.isHidden = state != .failed || !spelled
        needsDisplay = true
        agentLike.status =
            switch state {
            case .running: .working
            case .waiting: .waiting
            case .passed: .done
            case .failed, nil: nil
            }
    }

    /// The failure's dot, 6 pt in the mark's 12: drawn here, so it follows the appearance as text colours do.
    override func draw(_ dirtyRect: NSRect) {
        guard state == .failed, !spelled else { return }
        NSColor.textRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: bounds.width / 4, dy: bounds.height / 4)).fill()
    }

    /// An empty image: holds the mark's place in a button's title or image slot.
    static func room(_ side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in true }
    }
}
