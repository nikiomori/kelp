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

    package static func ago(_ iso: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d else { return "" }
        return Date().timeIntervalSince(d) < 60 ? shortAgo(d) : String(localized: "\(shortAgo(d)) ago")   // "now", not "now ago"
    }
}
