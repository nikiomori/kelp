import AppKit
import Core
import DesignKit
import SwiftUI

/// One look for agent state everywhere (sidebar, tabs, panes): a spinning ring while it works, a slow ring of dots once
/// it only waits for its command, an orange ◎ when it needs you, an outlined ✓ in the text's colour when it finished and
/// you haven't looked (filled and coloured marks are for what needs you: asking, failed), nothing after (as an agent that
/// did nothing), a moon when paused.
extension AgentStatus {
    package var symbol: String {
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
        case .done: .labelColor   // no state colour, and brighter than a working ring: it's what's new among the greys
        case .idle: .tertiaryLabelColor   // nothing to look at: it stays quiet
        case .paused: .secondaryLabelColor   // quiet, but a mark must still read (tertiary is about 2:1)
        case .exited: .secondaryLabelColor
        case .error: .systemRed
        }
    }
    var color: Color { Color(nsColor: nsColor) }
    /// Short, for rows: "Working", "Needs input"…
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
    /// Most urgent first: what a workspace shows when it has several agents.
    static let urgency: [AgentStatus] = [.waiting, .error, .working, .done, .idle, .paused, .exited]
    static func mostUrgent(_ statuses: [AgentStatus]) -> AgentStatus? {
        statuses.min { (urgency.firstIndex(of: $0) ?? 9) < (urgency.firstIndex(of: $1) ?? 9) }
    }
}

/// "now", "4m", "2h", "3d": how long ago, as short as a row allows.
package func shortAgo(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let elapsed = now.timeIntervalSince(date)
    return elapsed < 60 ? String(localized: "now") : shortSpan(elapsed)
}

/// "4m", "1d 3h": a span in Kelp's language, `units` parts at most (the last one rounded), down to `smallest`.
/// One formatter per kind, kept: every row on every sidebar pass and every clock tick made a new one.
package func shortSpan(_ seconds: Double, units: Int = 1, smallest: NSCalendar.Unit = .minute) -> String {
    let language = Bundle.main.preferredLocalizations.first ?? "en",
        key = "\(units) \(smallest.rawValue) \(language)" as NSString
    let formatter =
        spanFormatters.object(forKey: key)
        ?? {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = units
            formatter.allowedUnits = [.day, .hour, .minute, smallest]
            var calendar = Calendar.current
            calendar.locale = Locale(identifier: language)
            formatter.calendar = calendar
            spanFormatters.setObject(formatter, forKey: key)
            return formatter
        }()
    return formatter.string(from: max(0, seconds)) ?? ""
}
nonisolated(unsafe) private let spanFormatters = NSCache<NSString, DateComponentsFormatter>()   // NSCache is thread-safe, as is formatting

/// A status mark for AppKit. Ready agents show none.
@MainActor
package final class StatusMark: NSView {
    private let image = NSImageView()
    private let ring = CAShapeLayer()
    private let size: CGFloat
    package var status: AgentStatus? { didSet { if status != oldValue { update() } } }
    /// Done and not looked at yet: the filled ✓; seen: no mark.
    var unread = true { didSet { if unread != oldValue { update() } } }
    /// Working on shrinking its conversation (Claude's compaction): a slow pulse, not the spin.
    var compacting = false { didSet { if compacting != oldValue { update() } } }
    /// Its turn is over and it waits for its command to end (`Session.waitsForCommand`): a slow ring of dots, a shape of its
    /// own, so it still says so where nothing moves.
    var waitsForCommand = false { didSet { if waitsForCommand != oldValue { update() } } }
    /// Stopped by a plan limit, read or not: a clock, until it does something else.
    var limited = false { didSet { if limited != oldValue { update() } } }
    /// Its status is read off the screen (`Session.guessed`): a whole ring of dashes, a guess that looks like one.
    var guessed = false { didSet { if guessed != oldValue { update() } } }
    /// How far it got (0…1), when it says: a pie filling a circle, as Finder's and Safari's progress, not the spinning ring.
    var progress: Double? { didSet { if progress != oldValue { update() } } }
    /// Read by VoiceOver on its own; off where its row says the state in its own label (a sidebar agent).
    var announces = true { didSet { if announces != oldValue { update() } } }
    private let track = CAShapeLayer(), bar = CAShapeLayer()

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

    private func update() {
        let shown = !limited && (status == .idle || (status == .done && !unread)) ? nil : status
        let filling = shown == .working ? progress : nil
        isHidden = shown == nil
        let dotted = shown == .working && waitsForCommand && !compacting
        let dashed = shown == .working && guessed && !dotted && !compacting
        toolTip =
            filling.map { "\(shown?.words ?? "") · \(Int($0 * 100)) %" }
            ?? (dotted
                ? String(localized: "Waits for its command")
                : dashed ? String(localized: "Working, as far as the screen shows") : shown?.words)
        // VoiceOver reads the state (the spinning ring is only a layer): the same words as the tooltip.
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
            CATransaction.begin()
            CATransaction.setDisableActions(Motion.reduced)   // a layer of its own: it would ease over 0.25 s
            bar.strokeEnd = min(1, max(0, filling))
            CATransaction.commit()
            return
        }
        // Motion means state: spinning = working, pulsing = compacting, filled = waiting for you. With Reduce Motion a
        // still symbol says "working" instead: a ring that stopped spinning looks stuck.
        let still = Motion.reduced
        let spinning = shown == .working && !compacting && !still
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
            CATransaction.setDisableActions(true)   // a layer of its own: it would ease over 0.25 s
            // Eight round dots: a dash of nothing, drawn by its caps, wider than the arc's line to weigh as much as it does.
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
            // As EdgeGlow: one per working agent in its row, tab and summary kept the window drawing at 120 Hz for hours.
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            ring.add(spin, forKey: "spin")
            return
        }
        if shown == .working {
            image.image = .symbol(
                compacting ? "arrow.down.right.and.arrow.up.left" : "ellipsis.circle",
                compacting ? String(localized: "Compacting its conversation") : shown?.words ?? "")
            image.symbolConfiguration = .chrome(size - 2)
            image.contentTintColor = .secondaryLabelColor
            if compacting, !still {
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
        // The moon is wider than the circles: a size smaller, it takes the same room.
        image.symbolConfiguration = .chrome(shown == .paused ? size - 3 : size - 1)
        image.contentTintColor = shown.nsColor
    }
}

/// `StatusMark` in SwiftUI (a hover card, an extension's list): one look for a state, Reduce Motion included.
package struct StatusIcon: NSViewRepresentable {
    let status: AgentStatus
    var waitsForCommand = false
    package init(status: AgentStatus, waitsForCommand: Bool = false) {
        self.status = status
        self.waitsForCommand = waitsForCommand
    }
    package func makeNSView(context: Context) -> StatusMark { StatusMark(size: 12) }
    package func updateNSView(_ mark: StatusMark, context: Context) {
        mark.status = status
        mark.waitsForCommand = waitsForCommand
    }
}

extension Session {
    /// Ended on its own with a non-zero exit code (the daemon says so in the summary): shown red, not grey.
    var endedWithError: Bool { status == .exited && summary.hasPrefix("Ended with an error") }
    /// What its mark shows: a terminal or a command (not an agent) works while a program in it shows how far it got.
    package var markStatus: AgentStatus {
        progress != nil && (agent == "shell" || agent == "custom") ? .working : status
    }
    /// What its row's mark shows: a paused agent's row is dimmed, but what it finished and you haven't read keeps its
    /// bright mark.
    package var shownStatus: AgentStatus { status == .paused && unread ? .done : markStatus }
    /// "Working · 40 %" when it says how far it got.
    package var statusWords: String {
        let shown = markStatus
        return shown == .working ? progress.map { "\(shown.words) · \($0) %" } ?? shown.words : shown.words
    }
    /// "Works in .claude/worktrees/fix-login" when the agent went out of the folder it started in.
    package var workingElsewhere: String? {
        guard let dir = workDir else { return nil }
        let inside =
            dir.hasPrefix(cwd + "/")
            ? String(dir.dropFirst(cwd.count + 1)) : (dir as NSString).abbreviatingWithTildeInPath
        return String(localized: "Works in \(inside)")
    }
}

/// Agents waiting for the user, in the order to visit them: questions and failures before finished work, oldest first.
@MainActor
struct AttentionQueue {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    var sessions: [Session] {
        app.sessions
            .filter(SidebarCell.wantsYou)   // what the summary counts, a paused agent's unread result too
            .filter { $0.parent == nil || SidebarCell.shownStatus($0) != .done }   // a child's result goes to its parent, not you
            .filter { app.worktree($0.worktreeId).map { !$0.archived } == true }   // in a workspace on the sidebar (an archived one isn't loaded)
            .sorted { Self.order($0) < Self.order($1) }
    }

    /// Results last, then oldest first.
    private static func order(_ session: Session) -> (Int, Date) {
        (SidebarCell.shownStatus(session) == .done ? 1 : 0, session.statusAt ?? session.createdAt)
    }

    /// The one after `current` (wrapping), so pressing again walks the whole queue.
    func next(after current: String?) -> Session? {
        let queue = sessions
        guard let index = queue.firstIndex(where: { $0.id == current }) else { return queue.first }
        return queue.count > 1 ? queue[(index + 1) % queue.count] : nil
    }
}
