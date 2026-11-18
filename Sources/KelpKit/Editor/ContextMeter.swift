import AppKit
import Core
import DesignKit

@MainActor
/// Shows on an agent's tab how full its conversation is. It shows nothing while there's room, then a pie that fills:
/// yellow where answers may start to slip, orange where it's time to compact or hand off, and red just before the agent
/// compacts by itself. It is a pie, not an arc, because an arc in the same place as the working ring read as a second
/// spinner. Yellow starts past half a 200k window, or past 200k tokens of a bigger one, because long-context benchmarks
/// slip by absolute tokens. So a 1M window turns yellow at 200k, orange at 400k and red at 600k, and a 200k window at
/// 100k, 130k and 150k (under Claude Code's own compaction).
final class ContextMeter: NSView {
    private let track = CAShapeLayer(), fill = CAShapeLayer()
    var usage: SessionContextWindow.Usage? {
        didSet {
            isHidden = !Self.shows(usage)
            update()
        }
    }
    /// Returns the level: 0 room, 1 yellow, 2 orange, 3 red.
    static func level(_ usage: SessionContextWindow.Usage?) -> Int {
        guard let usage, usage.window > 0 else { return 0 }
        let window = Double(usage.window), used = Double(usage.used)
        return used >= min(0.75 * window, 600_000)
            ? 3 : used >= min(0.65 * window, 400_000) ? 2 : used >= min(0.5 * window, 200_000) ? 1 : 0
    }
    /// Whether the meter shows on a tab, which it does from yellow on.
    static func shows(_ usage: SessionContextWindow.Usage?) -> Bool { level(usage) >= 1 }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        // The pie is only drawn, so VoiceOver gets it as a level, in the tooltip's words.
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(String(localized: "Context"))
        // Draw the circle's edge, and inside it a 4 pt stroke along a circle of radius 2, so the stroke covers the pie
        // and strokeEnd fills it from the top, clockwise (the layer's y goes up). This is StatusMark's progress pie.
        track.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 10, height: 10), transform: nil)
        track.lineWidth = 1
        let pie = CGMutablePath()
        pie.addArc(
            center: CGPoint(x: 6, y: 6), radius: 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        fill.path = pie
        fill.lineWidth = 4
        for shape in [track, fill] {
            shape.fillColor = nil
            layer?.addSublayer(shape)
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }
    private func update() {
        guard let usage, usage.window > 0 else { return }
        let share = Double(usage.used) / Double(usage.window),
            color = [NSColor.systemYellow, .systemYellow, .systemOrange, .systemRed][Self.level(usage)]
        toolTip = String(
            localized: "Context \(Int(share * 100)) % full: \(usage.used / 1000)k of \(usage.window / 1000)k tokens")
        setAccessibilityValue(
            String(localized: "\(Int(share * 100)) % full: \(usage.used / 1000)k of \(usage.window / 1000)k tokens"))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = color.cgColor
            fill.strokeColor = color.cgColor
        }
        fill.animate("strokeEnd", to: min(1, share), duration: Motion.base)
    }
}
