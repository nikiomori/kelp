import AppKit
import Core
import DesignKit
import SwiftUI

/// One look for agent state everywhere (sidebar, tabs, panes). An agent shows a spinning ring while it works, a slow
/// ring of dots once it only waits for its command, and an orange ◎ when it needs you. When it finished and you haven't
/// looked, it shows an outlined ✓ in the text's colour (filled and coloured marks are for what needs you: asking,
/// failed). After that it shows nothing (like an agent that did nothing), and a moon when paused.
extension AgentStatus {
    var symbol: String {
        switch self {
        case .working: "circle.dotted"   // drawn as a spinning ring where there's room
        case .waiting: "record.circle"
        case .done: "checkmark.circle"
        case .idle: "circle"
        case .paused: "moon.fill"
        case .exited: "xmark.circle"
        case .error: "exclamationmark.circle.fill"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .working: .secondaryLabelColor
        case .waiting: .systemOrange
        case .done: .labelColor   // no state colour, but brighter than a working ring, as what's new among the greys
        case .idle: .tertiaryLabelColor   // nothing to look at, so it stays quiet
        case .paused: .secondaryLabelColor   // quiet, but a mark must still read (tertiary is about 2:1)
        case .exited: .secondaryLabelColor
        case .error: .systemRed
        }
    }
    var color: Color { Color(nsColor: nsColor) }
    /// Short words for rows: "Working", "Needs input"…
    package var words: String {
        switch self {
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Needs your input")
        case .done: String(localized: "Done")
        case .idle: String(localized: "Ready")
        case .paused: String(localized: "Paused")
        case .exited: String(localized: "Ended")
        case .error: String(localized: "Failed")
        }
    }
    /// The states, most urgent first. A workspace with several agents shows the most urgent one.
    static let urgency: [AgentStatus] = [.waiting, .error, .working, .done, .idle, .paused, .exited]
    static func mostUrgent(_ statuses: [AgentStatus]) -> AgentStatus? {
        statuses.min { (urgency.firstIndex(of: $0) ?? 9) < (urgency.firstIndex(of: $1) ?? 9) }
    }
}

/// A status mark for AppKit. Ready agents show none.
@MainActor
package final class StatusMark: NSView {
    private let image = NSImageView()
    private let ring = CAShapeLayer()
    private let size: CGFloat
    // A change of state fades from one mark to the next. That isn't done in `update`, which a theme or window change
    // runs too.
    package var status: AgentStatus? { didSet { if status != oldValue { changed() } } }
    /// True while a done agent hasn't been looked at, which shows the outlined ✓. Once it is seen, there is no mark.
    var unread = true { didSet { if unread != oldValue { changed() } } }
    /// True while the agent shrinks its conversation (Claude's compaction), shown as a slow pulse instead of the spin.
    var compacting = false { didSet { if compacting != oldValue { update() } } }
    /// True when the agent's turn is over and it waits for its command to end (`Session.waitsForCommand`). It shows a
    /// slow ring of dots, a shape of its own, so it still says so where nothing moves.
    var waitsForCommand = false { didSet { if waitsForCommand != oldValue { update() } } }
    /// True when a plan limit stopped the agent, read or not. It shows a clock until the agent does something else.
    var limited = false { didSet { if limited != oldValue { changed() } } }
    /// True when the status is read off the screen (`Session.guessed`). It shows a whole ring of dashes, so the guess
    /// looks like one.
    var guessed = false { didSet { if guessed != oldValue { update() } } }
    /// How far the agent got (0…1), when it says so. It shows as a pie filling a circle, as in Finder's and Safari's
    /// progress, instead of the spinning ring.
    var progress: Double? { didSet { if progress != oldValue { update() } } }
    /// Whether VoiceOver reads the mark on its own. It is off where the row says the state in its own label (a sidebar
    /// agent).
    var announces = true { didSet { if announces != oldValue { update() } } }
    private let track = CAShapeLayer(), bar = CAShapeLayer()

    /// Sets how the mark draws `session` at work: a ring of dots while it waits for its command, dashes for a guess, a
    /// pulse while it compacts, a pie for how far it got, a clock at its limit. Every place that shows a chat's mark
    /// sets these with this, after the status it shows there. Each copied them by hand, some two of the five and a
    /// folded project's logos none, so one agent stood as a ring of dots in its tab and turned as an arc in the list.
    func follow(_ session: Session) {
        limited = session.limitHit != nil
        compacting = session.compacting
        waitsForCommand = session.waitsForCommand
        guessed = session.guessed == true
        progress = session.progress.map { Double($0) / 100 }
    }

    package init(size: CGFloat = 12) {
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.lineCap = .round
        let inset: CGFloat = 1.5
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.path = CGPath(
            ellipseIn: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset), transform: nil)
        ring.strokeEnd = 0.75
        layer?.addSublayer(ring)
        // The pie is a stroke as wide as its radius around half of it, so strokeEnd fills it from the top, clockwise.
        let pie = (size / 2 - inset) - 1.5, arc = CGMutablePath()
        arc.addArc(
            center: CGPoint(x: size / 2, y: size / 2), radius: pie / 2, startAngle: .pi / 2,
            endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        track.path = ring.path
        track.lineWidth = 1
        bar.path = arc
        bar.lineWidth = pie
        for shape in [track, bar] {
            shape.frame = ring.frame
            shape.fillColor = nil
            layer?.addSublayer(shape)
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        followReduceMotion(#selector(motionChanged))
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func motionChanged() { update() }
    override package func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }
    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }   // animations stop when a view leaves a window

    private func changed() {
        // A reused cell that is being filled shows at once. A mark that goes away (a done one that was read) fades
        // where it stood as a ghost, because a fade on its own layer, hidden at once, never showed.
        if window != nil, !isHidden, shown == nil, let parent = superview {
            leaveGhost(in: parent, duration: Motion.slow)
        } else if window != nil {
            crossfade()
        }
        update()
    }

    /// The state the mark shows. It shows nothing for an idle agent or for a done one already looked at.
    private var shown: AgentStatus? { !limited && (status == .idle || (status == .done && !unread)) ? nil : status }

    private func update() {
        let filling = shown == .working ? progress : nil
        isHidden = shown == nil
        let dotted = shown == .working && waitsForCommand && !compacting
        let dashed = shown == .working && guessed && !dotted && !compacting
        toolTip =
            filling.map { "\(shown?.words ?? "") · \(Int($0 * 100)) %" }
            ?? (dotted
                ? String(localized: "Waits for its command")
                : dashed ? String(localized: "Working, as far as the screen shows") : shown?.words)
        // VoiceOver reads the state with the same words as the tooltip, because the spinning ring is only a layer.
        setAccessibilityElement(shown != nil && announces)
        setAccessibilityRole(.image)
        setAccessibilityLabel(
            compacting && shown == .working ? String(localized: "Compacting its conversation") : toolTip)
        track.isHidden = filling == nil
        bar.isHidden = filling == nil
        if let filling {
            ring.isHidden = true
            image.isHidden = true
            ring.removeAllAnimations()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                track.strokeColor = NSColor.secondaryLabelColor.cgColor
                bar.strokeColor = NSColor.secondaryLabelColor.cgColor
            }
            bar.animate("strokeEnd", to: min(1, max(0, filling)), duration: Motion.base)
            return
        }
        // Motion means state: spinning = working, pulsing = compacting, filled = waiting for you. With Reduce Motion
        // the same ring stands still, because a state keeps its shape whatever the setting, and three dots in a circle
        // are the "more" button.
        let still = Motion.reduced
        let spinning = shown == .working && !compacting
        ring.isHidden = !spinning && !dotted
        image.isHidden = spinning || dotted
        ring.removeAllAnimations()
        image.layer?.removeAllAnimations()
        image.alphaValue = 1
        if spinning || dotted {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.strokeColor = NSColor.secondaryLabelColor.cgColor
            }
            ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            ring.position = CGPoint(x: size / 2, y: size / 2)
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // a layer of its own would ease over 0.25 s
            // Eight round dots, each a zero-length dash drawn by its round caps. The line is wider than the arc's, so
            // the dots weigh as much as the arc.
            ring.lineDashPattern = dotted ? [0, NSNumber(value: Double.pi * (size - 3) / 8)] : dashed ? [2, 2.4] : nil
            ring.lineWidth = dotted ? 2 : 1.5
            ring.strokeEnd = dotted || dashed ? 1 : 0.75
            CATransaction.commit()
            guard !still else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = dotted ? Motion.wait : Motion.spin
            spin.repeatCount = .infinity
            spin.beginTime = Motion.beat(spin.duration)
            // Capped as in EdgeGlow, because one ring per working agent in its row, tab and summary kept the window
            // drawing at 120 Hz for hours.
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            ring.add(spin, forKey: "spin")
            return
        }
        if shown == .working {   // compacting: any other work is the ring above
            image.image = .symbol(
                "arrow.down.right.and.arrow.up.left", String(localized: "Compacting its conversation"))
            image.symbolConfiguration = .chrome(size - 2)
            image.contentTintColor = .secondaryLabelColor
            if !still {
                image.wantsLayer = true
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.3
                pulse.duration = Motion.pulse
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.beginTime = Motion.beat(2 * pulse.duration)
                image.layer?.add(pulse, forKey: "pulse")
            }
            return
        }
        guard let shown else { return }
        if limited {
            image.image = .symbol("clock", String(localized: "Stopped at its limit"))
            image.symbolConfiguration = .chrome(size - 1)
            image.contentTintColor = .textOrange
            return
        }
        image.image = .symbol(shown.symbol, shown.words)
        // The moon is wider than the circles, so it is drawn a size smaller to take the same room.
        image.symbolConfiguration = .chrome(shown == .paused ? size - 3 : size - 1)
        image.contentTintColor = shown.nsColor
    }
}

/// `StatusMark` in SwiftUI (for a hover card or an extension's list), so a state has one look, Reduce Motion included.
package struct StatusIcon: NSViewRepresentable {
    let status: AgentStatus
    /// The chat the state is of, when it is one's: the mark says how it works, too (`StatusMark.follow`).
    let session: Session?
    package init(status: AgentStatus, of session: Session? = nil) {
        self.status = status
        self.session = session
    }
    package func makeNSView(context: Context) -> StatusMark { StatusMark(size: 12) }
    package func updateNSView(_ mark: StatusMark, context: Context) {
        mark.status = status
        if let session { mark.follow(session) }
    }
}
