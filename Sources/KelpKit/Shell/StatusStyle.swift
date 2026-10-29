import AppKit
import SwiftUI
import Core

/// One look for agent state everywhere (sidebar, tabs, panes): a spinning ring while it works, an orange ◎ when it
/// needs you, a filled grey ✓ when it finished and you haven't looked, nothing after (as an agent that did nothing),
/// a moon when paused.
extension AgentStatus {
    package var symbol: String {
        switch self {
        case .working: "circle.dotted"           // drawn as a spinning ring where there's room
        case .waiting: "record.circle"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .hibernated: "moon.fill"
        case .exited: "xmark.circle"
        case .error: "exclamationmark.circle.fill"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .working: .secondaryLabelColor
        case .waiting: .systemOrange
        case .done: .secondaryLabelColor   // quiet: what's new is said by the bold name and the line over the list
        case .idle: .tertiaryLabelColor   // nothing to look at: it stays quiet
        case .hibernated: .secondaryLabelColor   // quiet, but a mark must still read (tertiary is about 2:1)
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
        case .hibernated: String(localized: "Paused")
        case .exited: String(localized: "Ended")
        case .error: String(localized: "Failed")
        }
    }
    /// Most urgent first: what a workspace shows when it has several agents.
    static let urgency: [AgentStatus] = [.waiting, .error, .working, .done, .idle, .hibernated, .exited]
    static func mostUrgent(_ s: [AgentStatus]) -> AgentStatus? { s.min { (urgency.firstIndex(of: $0) ?? 9) < (urgency.firstIndex(of: $1) ?? 9) } }
}

/// "now", "4m", "2h", "3d": how long ago, as short as a row allows.
package func shortAgo(_ d: Date?, now: Date = Date()) -> String {
    guard let d else { return "" }
    let s = now.timeIntervalSince(d)
    return s < 60 ? String(localized: "now") : shortSpan(s)
}

/// "4m", "1d 3h": a span in Kelp's language, `units` parts at most (the last one rounded), down to `smallest`.
package func shortSpan(_ seconds: Double, units: Int = 1, smallest: NSCalendar.Unit = .minute) -> String {
    let f = DateComponentsFormatter()
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = units
    f.allowedUnits = [.day, .hour, .minute, smallest]
    var c = Calendar.current
    c.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    f.calendar = c
    return f.string(from: max(0, seconds)) ?? ""
}

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
    /// How far it got (0…1), when it says: a pie filling a circle, as Finder's and Safari's progress, not the spinning ring.
    var progress: Double? { didSet { if progress != oldValue { update() } } }
    /// Read by VoiceOver on its own; off where its row says the state in its own label (a sidebar agent).
    var announces = true { didSet { if announces != oldValue { update() } } }
    private let track = CAShapeLayer(), bar = CAShapeLayer()

    package init(size: CGFloat = 12) {
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        image.translatesAutoresizingMaskIntoConstraints = false; addSubview(image)
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.lineCap = .round
        let inset: CGFloat = 1.5
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.path = CGPath(ellipseIn: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset), transform: nil)
        ring.strokeEnd = 0.75
        layer?.addSublayer(ring)
        // The pie is a stroke as wide as its radius around half of it, so strokeEnd fills it from the top, clockwise.
        let pie = (size / 2 - inset) - 1.5, arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: pie / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        track.path = ring.path
        track.lineWidth = 1
        bar.path = arc
        bar.lineWidth = pie
        for l in [track, bar] {
            l.frame = ring.frame
            l.fillColor = nil
            layer?.addSublayer(l)
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override package func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update() }
    override package func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update() }   // animations stop when a view leaves a window

    private func update() {
        let s = status == .idle || (status == .done && !unread) ? nil : status
        let filling = s == .working ? progress : nil
        isHidden = s == nil
        toolTip = filling.map { "\(s?.words ?? "") · \(Int($0 * 100)) %" } ?? s?.words
        // VoiceOver reads the state (the spinning ring is only a layer): the same words as the tooltip.
        setAccessibilityElement(s != nil && announces); setAccessibilityRole(.image)
        setAccessibilityLabel(compacting && s == .working ? String(localized: "Compacting its conversation") : toolTip)
        track.isHidden = filling == nil; bar.isHidden = filling == nil
        if let filling {
            ring.isHidden = true
            image.isHidden = true
            ring.removeAllAnimations()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                track.strokeColor = NSColor.secondaryLabelColor.cgColor; bar.strokeColor = NSColor.secondaryLabelColor.cgColor
            }
            bar.strokeEnd = min(1, max(0, filling))
            return
        }
        // Motion means state: spinning = working, pulsing = compacting, filled = waiting for you. With Reduce Motion a
        // still symbol says "working" instead: a ring that stopped spinning looks stuck.
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let spinning = s == .working && !compacting && !still
        ring.isHidden = !spinning; image.isHidden = spinning
        ring.removeAllAnimations()
        image.layer?.removeAllAnimations()
        image.alphaValue = 1
        if spinning {
            effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = NSColor.secondaryLabelColor.cgColor }
            ring.anchorPoint = CGPoint(x: 0.5, y: 0.5); ring.position = CGPoint(x: size / 2, y: size / 2)
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi
            a.duration = 1
            a.repeatCount = .infinity
            ring.add(a, forKey: "spin")
            return
        }
        if s == .working {
            image.image = .symbol(compacting ? "arrow.down.right.and.arrow.up.left" : "ellipsis.circle",
                compacting ? String(localized: "Compacting its conversation") : s?.words ?? "")
            image.symbolConfiguration = .init(pointSize: size - 2, weight: .regular); image.contentTintColor = .secondaryLabelColor
            if compacting, !still {
                image.wantsLayer = true
                let p = CABasicAnimation(keyPath: "opacity")
                p.fromValue = 1
                p.toValue = 0.3
                p.duration = 0.9
                p.autoreverses = true; p.repeatCount = .infinity
                image.layer?.add(p, forKey: "pulse")
            }
            return
        }
        guard let s else { return }
        image.image = .symbol(s.symbol, s.words)
        // The moon is wider than the circles: a size smaller, it takes the same room.
        image.symbolConfiguration = .init(pointSize: s == .hibernated ? size - 3 : size - 1, weight: .regular)
        image.contentTintColor = s.nsColor
    }
}

/// Status as an SF Symbol, animated while the agent works.
struct StatusIcon: View {
    let status: AgentStatus
    var body: some View {
        Image(systemName: status == .working ? "circle.dotted" : status.symbol)
            .foregroundStyle(status.color)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: status == .working)
            .help(status.words)
    }
}

extension Session {
    /// Ended on its own with a non-zero exit code (the daemon says so in the summary): shown red, not grey.
    package var endedWithError: Bool { status == .exited && summary.hasPrefix("Ended with an error") }
    /// What its mark shows: a terminal or a command (not an agent) works while a program in it shows how far it got.
    package var markStatus: AgentStatus { progress != nil && (agent == "shell" || agent == "custom") ? .working : status }
    /// "Working · 40 %" when it says how far it got.
    package var statusWords: String { let s = markStatus; return s == .working ? progress.map { "\(s.words) · \($0) %" } ?? s.words : s.words }
    /// What it runs in the background, for the chip on its tab and row, whatever it's doing (asking included): the command it
    /// waits for, else how many run (a dev server from an earlier turn). nil when none, or its program is gone.
    var backgroundLabel: String? {
        guard let b = background, !b.isEmpty, status != .exited, status != .hibernated else { return nil }
        return awaiting ?? "\(b.count)"
    }
    /// The chip's tooltip: the whole list.
    var backgroundTip: String? {
        guard backgroundLabel != nil, let b = background else { return nil }
        return (waitsForCommand ? String(localized: "Waits for its command:") : String(localized: "Running in the background:"))
            + "\n" + b.joined(separator: "\n")
    }
    /// It works on only to see that command end: its tab glows cyan. Not while it asks, and not for a server.
    var waitsForCommand: Bool { status == .working && awaiting != nil }
    /// "Works in .claude/worktrees/fix-login" when the agent went out of the folder it started in.
    package var workingElsewhere: String? {
        guard let d = workDir else { return nil }
        let inside = d.hasPrefix(cwd + "/") ? String(d.dropFirst(cwd.count + 1)) : (d as NSString).abbreviatingWithTildeInPath
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
            .filter { app.worktree($0.worktreeId).map { !$0.archived } == true }   // in a workspace on the sidebar (an archived one isn't loaded)
            .sorted {
                (SidebarCell.shownStatus($0) == .done ? 1 : 0, $0.statusAt ?? $0.createdAt)
                    < (SidebarCell.shownStatus($1) == .done ? 1 : 0, $1.statusAt ?? $1.createdAt)
            }
    }

    /// The one after `current` (wrapping), so pressing again walks the whole queue.
    func next(after current: String?) -> Session? {
        let q = sessions
        guard let i = q.firstIndex(where: { $0.id == current }) else { return q.first }
        return q.count > 1 ? q[(i + 1) % q.count] : nil
    }
}
