import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The row over the projects, beside Add Project. While agents need you: a glass capsule counting them, which goes to the
/// next one, as ⇧⌘U does. Beside it in grey, how many work and how many finished unread: words, not a button, so nothing
/// says more than the capsule's click does. The rows say what each one wants (SidebarCell's second line), so the capsule doesn't list them again. With
/// nobody asking and nobody working the row names the list under it. It keeps its place whatever it says: nothing in the
/// list moves when an agent starts asking or stops. A new question lights the capsule up for a moment.
@MainActor
final class AgentSummary: NSView {
    private let capsule = Pressable()
    /// Liquid Glass where there is (macOS 26): the one custom glass in the sidebar, over the list it floats above.
    private let glass: NSView = {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = Metrics.radiusXL
            return g
        }
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .withinWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = Metrics.radiusXL
        v.layer?.masksToBounds = true
        return v
    }()
    /// Over the glass, under the words: the grey the pointer brings (a fill behind the glass wouldn't show).
    private let sheen = NSView()
    private let mark = StatusMark(size: 12)
    private let title = NSTextField(labelWithString: "")
    /// What's said beside the capsule, or alone in its place: how many work, or the list's name.
    private let aside = NSStackView()
    private let asideMark = StatusMark(size: 12)
    private let asideText = NSTextField(labelWithString: "")
    private let doneMark = StatusMark(size: 12)
    private let doneText = NSTextField(labelWithString: "")
    private let row = NSStackView()
    /// The words' room, as wished rather than required: a stack around a label has no width of its own, and a required one
    /// would widen the sidebar.
    private lazy var asideWidth: NSLayoutConstraint = {
        let c = aside.widthAnchor.constraint(equalToConstant: 0)
        c.priority = .defaultHigh
        c.isActive = true
        return c
    }()
    private let app: AppModel
    private var asking = false
    /// Questions already shown or looked at: one that isn't lights the capsule as it comes in.
    private var seen: Set<String>?
    private var settleTimer: Timer?

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        title.maximumNumberOfLines = 1
        title.font = .ui(12, weight: .semibold)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let content = NSStackView(views: [mark, title])
        content.spacing = Metrics.gap
        sheen.wantsLayer = true
        sheen.layer?.cornerRadius = Metrics.radiusXL
        sheen.layer?.cornerCurve = .continuous
        for v in [glass, sheen, content] { v.translatesAutoresizingMaskIntoConstraints = false; capsule.addSubview(v) }
        capsule.contextMenu = { [weak self] in self.map { Self.viewMenu($0.app) } }
        capsule.press = { [weak self] in self?.app.workbench.showNextNeedingAttention() }
        capsule.look = { [weak self] hovering, pressed in
            self?.sheen.fadeBackground(to: pressed ? .fillSelected : hovering ? .fillHover : nil, held: pressed)
        }
        capsule.setAccessibilityElement(true)
        capsule.setAccessibilityRole(.button)
        asideText.textColor = .secondaryLabelColor
        asideText.lineBreakMode = .byClipping
        asideText.maximumNumberOfLines = 1
        asideText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        doneText.font = .ui(11)
        doneText.textColor = .secondaryLabelColor
        doneMark.status = .done
        doneMark.announces = false
        for v in [asideMark, asideText, doneMark, doneText] as [NSView] { aside.addArrangedSubview(v) }
        aside.spacing = Metrics.gap
        aside.detachesHiddenViews = true
        for v in [capsule, aside] as [NSView] { row.addArrangedSubview(v) }
        row.spacing = Metrics.gap
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TextSize.of(24)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            capsule.heightAnchor.constraint(equalToConstant: TextSize.of(24)),
            glass.topAnchor.constraint(equalTo: capsule.topAnchor), glass.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: capsule.leadingAnchor), glass.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            sheen.topAnchor.constraint(equalTo: glass.topAnchor), sheen.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            sheen.leadingAnchor.constraint(equalTo: glass.leadingAnchor), sheen.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -12)
        ])
        track(owner: self) { [app] in app.sessions } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app] in app.repos } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app] in app.workbench.focusedTab } changed: { [weak self] _ in self?.update() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A mark has no size of its own, only constraints.
    private static func width(_ views: [NSView], gap: CGFloat) -> CGFloat {
        views.reduce(0) { $0 + ($1 is StatusMark ? 12 : $1.intrinsicContentSize.width) } + CGFloat(max(views.count - 1, 0)) * gap + 2
    }

    /// The grey words go first when the row is short of room (a large Text size): the capsule says what matters.
    override func layout() {
        super.layout()
        let room = asking ? bounds.width - (title.intrinsicContentSize.width + 12 + Metrics.gap + 22) - row.spacing : .infinity
        let working = [asideMark, asideText].filter { !$0.isHidden } as [NSView]
        let finished: [NSView] = doneText.stringValue.isEmpty ? [] : [doneMark, doneText]
        let fits = Self.width(working + finished, gap: aside.spacing) <= room   // what finished goes first: it asks for nothing
        for v in [doneMark, doneText] as [NSView] { v.isHidden = !fits || finished.isEmpty }
        let parts = fits ? working + finished : working
        let words = Self.width(parts, gap: aside.spacing)
        if asideWidth.constant != words { asideWidth.constant = words }
        let hide = parts.isEmpty || words > room
        if aside.isHidden != hide { aside.isHidden = hide }
    }

    func update() {
        let inbox = Inbox.current(app)
        let shown = inbox.shown
        settleTimer?.invalidate(); settleTimer = nil
        if let due = inbox.settlesAt {
            settleTimer = Timer.scheduledTimer(withTimeInterval: due.timeIntervalSinceNow, repeats: false) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.update() }
            }
        }
        let busy = app.sessions.filter { $0.isChat && $0.status == .working }.count
        let done = AttentionQueue(app).sessions.filter { SidebarCell.shownStatus($0) == .done }.count
        let questions = Set(inbox.queue.map(\.id)), new = shown.map(\.id).filter { !(seen ?? questions).contains($0) }
        seen = (seen ?? questions).union(shown.map(\.id)).union(inbox.viewing).intersection(questions)

        isHidden = app.repos.allSatisfy(ScratchWindow.isScratch)   // the first run says it in the middle of the window
        asking = !shown.isEmpty
        capsule.isHidden = !asking
        capsule.refreshPointer()   // no longer asking: no grey left over from the pointer
        // Alone in the row the words stand in the icons' column; beside the capsule, a step from it.
        row.edgeInsets.left = asking ? 0 : Metrics.gapWide
        mark.status = AgentStatus.mostUrgent(shown.map(SidebarCell.shownStatus))
        mark.unread = true
        title.stringValue = String(localized: "\(shown.count) need you")
        asideMark.status = busy > 0 ? .working : nil
        asideMark.unread = true
        asideMark.isHidden = busy == 0
        asideText.stringValue = busy > 0 ? String(localized: "\(busy) working") : asking || done > 0 ? "" : String(localized: "Projects")
        asideText.isHidden = asideText.stringValue.isEmpty
        doneText.stringValue = done > 0 ? String(localized: "\(done) done") : ""
        asideText.font = busy > 0 ? .ui(11) : .ui(11, weight: .semibold)
        aside.isHidden = busy == 0 && done == 0 && asking
        needsLayout = true
        capsule.setAccessibilityLabel(String(localized: "Agents that need you: \(shown.count). Show the next one."))
        capsule.toolTip = String(localized: "Show the next agent that needs you (⇧⌘U)")
        if !new.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {   // a question came in: a brief glow
            capsule.alphaValue = 0.4
            NSAnimationContext.runAnimationGroup { $0.duration = Motion.appear; capsule.animator().alphaValue = 1 }
        }
    }

    /// The capsule's: where who waits for you is, and what their rows say.
    static func viewMenu(_ app: AppModel) -> NSMenu {
        let m = NSMenu()
        m.add(String(localized: "Show Agent Needing You")) { app.workbench.showNextNeedingAttention() }
        m.addItem(.separator())
        m.addChoices("workbench.sidebar.agentDetail", app, heading: String(localized: "Second Line"))
        m.addItem(.separator())
        m.addSettingsLink(String(localized: "Needs You Settings…"), section: "window", group: "Sidebar", app)
        return m
    }
}

extension Inbox {
    /// Who needs you now: the agent on screen isn't counted.
    @MainActor static func current(_ app: AppModel) -> Inbox {
        // A finished agent keeps its mark in the row: it asks for nothing, so it isn't counted as needing you.
        var inbox = Inbox(queue: AttentionQueue(app).sessions.filter { SidebarCell.shownStatus($0) != .done })
        let tab = app.workbench.focusedTab ?? ""
        if TabURI.scheme(tab) == "session" { inbox.viewing = [TabURI.body(tab)] }
        return inbox
    }
}

/// The capsule a click or VoiceOver presses: under the pointer its glass greys a step (`look`), held a step more, and a
/// click springs it (`PointerControl`).
@MainActor
private final class Pressable: PointerControl {
    var press: () -> Void = {}
    var look: (_ hovering: Bool, _ pressed: Bool) -> Void = { _, _ in }
    var contextMenu: (() -> NSMenu?)?
    override func clicked() { press() }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func showPointer(hovering: Bool, pressed: Bool) { look(hovering, pressed) }
}
