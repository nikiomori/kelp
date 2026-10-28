import AppKit
import Core
import DesignKit
import WorkbenchKit

/// One line over the projects about the agents. While some need you: a glass capsule counting them ("2 need you ·
/// 1 working") that goes to the next one, as ⇧⌘U does. Otherwise how many work, in grey on the projects' icon axis.
/// The rows say what each one wants (SidebarCell's second line), so the capsule doesn't list them again. The line
/// keeps its height whatever it says: nothing in the list moves when an agent starts asking or stops. A new question
/// lights the capsule up for a moment. Nobody asking and nobody working: the line goes.
@MainActor
final class AgentSummary: NSView {
    /// The line's place in the layout: the list starts under it.
    let line = NSLayoutGuide()
    private let capsule = Pressable()
    /// Liquid Glass where there is (macOS 26): the one custom glass in the sidebar, over the list it floats above.
    private let glass: NSView = {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 12
            return g
        }
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .withinWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.masksToBounds = true
        return v
    }()
    private let mark = StatusMark(size: 12)
    private let title = NSTextField(labelWithString: "")
    private var lineHeight: NSLayoutConstraint?
    private var centered: [NSLayoutConstraint] = [], leading: [NSLayoutConstraint] = []
    private let app: AppModel
    private var asking = false
    /// Questions already shown or looked at: one that isn't lights the capsule as it comes in.
    private var seen: Set<String>?
    private var settleTimer: Timer?
    /// After each update: who needs you may have changed (Automatic looks whether they are all in view).
    var updated: () -> Void = {}

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = NSStackView(views: [mark, title])
        content.spacing = 6
        content.detachesHiddenViews = true
        addLayoutGuide(line)
        for v in [glass, content] { v.translatesAutoresizingMaskIntoConstraints = false; capsule.addSubview(v) }
        capsule.translatesAutoresizingMaskIntoConstraints = false; addSubview(capsule)
        capsule.press = { [weak self] in if self?.asking == true { self?.app.workbench.showNextNeedingAttention() } }
        capsule.setAccessibilityElement(true)
        let lh = line.heightAnchor.constraint(equalToConstant: 0)
        lineHeight = lh
        NSLayoutConstraint.activate([
            lh, heightAnchor.constraint(equalTo: line.heightAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.centerYAnchor.constraint(equalTo: line.centerYAnchor), capsule.heightAnchor.constraint(equalToConstant: TextSize.of(24)),
            capsule.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            glass.topAnchor.constraint(equalTo: capsule.topAnchor), glass.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: capsule.leadingAnchor), glass.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: capsule.centerYAnchor), content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -12)
        ])
        // Asking, a capsule in the middle; otherwise the grey count where the projects' icons start (8 pt in, as the cards).
        centered = [capsule.centerXAnchor.constraint(equalTo: centerXAnchor), content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 10)]
        leading = [capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor)]
        NSLayoutConstraint.activate(leading)
        track(owner: self) { [app] in app.sessions } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app] in app.workbench.focusedTab } changed: { [weak self] _ in self?.update() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        let inbox = Inbox.current(app)
        let shown = inbox.shown
        settleTimer?.invalidate(); settleTimer = nil
        if let due = inbox.settlesAt {
            settleTimer = Timer.scheduledTimer(withTimeInterval: due.timeIntervalSinceNow, repeats: false) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.update() }
            }
        }
        let agents = app.sessions.filter { $0.agent != "shell" && $0.status != .exited }
        let busy = agents.filter { $0.status == .working }.count
        let asks = { (s: Session) in SidebarCell.shownStatus(s) != .done }
        let questions = Set(inbox.queue.filter(asks).map(\.id)), new = shown.filter(asks).map(\.id).filter { !(seen ?? questions).contains($0) }
        seen = (seen ?? questions).union(shown.filter(asks).map(\.id)).union(inbox.viewing).intersection(questions)

        isHidden = busy == 0 && shown.isEmpty   // nothing to say: no empty band over the list
        lineHeight?.constant = isHidden ? 0 : TextSize.of(30)
        asking = !shown.isEmpty
        glass.isHidden = !asking
        NSLayoutConstraint.deactivate(asking ? leading : centered)
        NSLayoutConstraint.activate(asking ? centered : leading)
        mark.status = asking ? AgentStatus.mostUrgent(shown.map(SidebarCell.shownStatus)) : busy > 0 ? .working : nil
        mark.unread = true
        let t = NSMutableAttributedString()
        if asking {
            t.append(NSAttributedString(string: String(localized: "\(shown.count) need you"),
                                        attributes: [.font: NSFont.ui(12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            if busy > 0 {
                t.append(NSAttributedString(string: "  ·  " + String(localized: "\(busy) working"),
                                            attributes: [.font: NSFont.ui(12), .foregroundColor: NSColor.secondaryLabelColor]))
            }
        } else if busy > 0 {
            t.append(NSAttributedString(string: String(localized: "\(busy) working"),
                                        attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        title.attributedStringValue = t
        capsule.setAccessibilityRole(asking ? .button : .staticText)
        capsule.setAccessibilityLabel(asking ? String(localized: "Agents that need you: \(shown.count). Show the next one.") : title.stringValue)
        capsule.toolTip = asking ? String(localized: "Show the next agent that needs you (⇧⌘U)") : nil
        if !new.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {   // a question came in: a brief glow
            capsule.alphaValue = 0.4
            NSAnimationContext.runAnimationGroup { $0.duration = 0.5; capsule.animator().alphaValue = 1 }
        }
        updated()
    }
}

/// A view a click or VoiceOver presses.
@MainActor
private final class Pressable: NSView {
    var press: () -> Void = {}
    override func mouseDown(with e: NSEvent) { press() }
    override func accessibilityPerformPress() -> Bool { press(); return true }
}
