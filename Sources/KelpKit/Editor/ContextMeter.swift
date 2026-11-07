import AppKit
import Core
import DesignKit

@MainActor
/// How full an agent's conversation is, on its tab: nothing while there's room, then a pie that fills, yellow where answers
/// may start to slip, orange where it's time to compact or hand off, red just before the agent compacts by itself. A pie,
/// not an arc: an arc in the same place as the working ring read as a second spinner. Past half a 200k window, or 200k tokens of a bigger one: long-context benchmarks slip by absolute tokens, so a 1M
/// window turns yellow at 200k, orange at 400k and red at 600k (a 200k one at 100k, 130k and 150k, under Claude Code's
/// own compaction).
final class ContextMeter: NSView {
    private let track = CAShapeLayer(), fill = CAShapeLayer()
    var usage: SessionContextWindow.Usage? {
        didSet {
            isHidden = !Self.shows(usage)
            update()
        }
    }
    /// 0 room, 1 yellow, 2 orange, 3 red.
    static func level(_ u: SessionContextWindow.Usage?) -> Int {
        guard let u, u.window > 0 else { return 0 }
        let w = Double(u.window), used = Double(u.used)
        return used >= min(0.75 * w, 600_000)
            ? 3 : used >= min(0.65 * w, 400_000) ? 2 : used >= min(0.5 * w, 200_000) ? 1 : 0
    }
    /// On a tab from yellow on.
    static func shows(_ u: SessionContextWindow.Usage?) -> Bool { level(u) >= 1 }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        // A circle's edge, and inside it a stroke as wide as half its radius around a quarter of it, so strokeEnd fills
        // the pie from the top, clockwise (the layer's y goes up): StatusMark's progress pie.
        track.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 10, height: 10), transform: nil)
        track.lineWidth = 1
        let pie = CGMutablePath()
        pie.addArc(
            center: CGPoint(x: 6, y: 6), radius: 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        fill.path = pie
        fill.lineWidth = 4
        for l in [track, fill] {
            l.fillColor = nil
            layer?.addSublayer(l)
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = color.cgColor
            fill.strokeColor = color.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(Motion.reduced)
        fill.strokeEnd = min(1, share)
        CATransaction.commit()
    }
}
