import AppKit
import Core
import DesignKit

@MainActor
/// How full an agent's conversation is: nothing while there's room, then a ring that fills, yellow where answers may
/// start to slip, orange where it's time to compact or hand off, red just before the agent compacts by itself. Past
/// half a 200k window, or 200k tokens of a bigger one: long-context benchmarks slip by absolute tokens, so a 1M
/// window turns yellow at 200k, orange at 400k and red at 600k (a 200k one at 100k, 130k and 150k, under Claude Code's
/// own compaction).
final class ContextMeter: NSView {
    private let track = CAShapeLayer(), fill = CAShapeLayer()
    var usage: SessionContextWindow.Usage? { didSet { isHidden = Self.level(usage) == 0; update() } }
    /// 0 room, 1 yellow, 2 orange, 3 red.
    static func level(_ u: SessionContextWindow.Usage?) -> Int {
        guard let u, u.window > 0 else { return 0 }
        let w = Double(u.window), used = Double(u.used)
        return used >= min(0.75 * w, 600_000) ? 3 : used >= min(0.65 * w, 400_000) ? 2 : used >= min(0.5 * w, 200_000) ? 1 : 0
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true; isHidden = true
        let path = CGMutablePath()   // from the top, clockwise (the layer's y goes up)
        path.addArc(center: CGPoint(x: 6, y: 6), radius: 4.5, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [track, fill] {
            l.path = path
            l.fillColor = nil
            l.lineWidth = 2
            layer?.addSublayer(l)
        }
        fill.lineCap = .round
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update() }
    private func update() {
        guard let usage, usage.window > 0 else { return }
        let share = Double(usage.used) / Double(usage.window), level = Self.level(usage)
        toolTip = String(localized: "Context \(Int(share * 100)) % full: \(usage.used / 1000)k of \(usage.window / 1000)k tokens")
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.tertiaryLabelColor.cgColor
            fill.strokeColor = [NSColor.secondaryLabelColor, .systemYellow, .systemOrange, .systemRed][level].cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(Motion.reduced)
        fill.strokeEnd = min(1, share)
        CATransaction.commit()
    }
}
