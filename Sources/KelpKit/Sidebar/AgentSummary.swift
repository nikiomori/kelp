import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The row above the projects, beside Add Project. The count of agents that need you is a glass capsule, and a click
/// on it goes to the next one, as ⇧⌘U does. Beside it, each other count is a button of its own (`SummarySegment`):
/// working, at a limit, quiet, done. A click on a count goes to the next chat it counts. Resting the pointer on a count
/// shows its chats (`SummaryCard`) and lights their rows in the list. A chat that just finished or hit its limit is
/// named in its count for a few seconds. With nothing to count (or no project yet), the row shows the name of the list
/// under it. The row keeps its place whatever it says, so nothing in the list moves.
@MainActor
final class AgentSummary: NSView {
    private let capsule = Pressable()
    /// Liquid Glass where the system has it (macOS 26). It is the only custom glass in the sidebar, floating over the
    /// list.
    private let glass: NSView = {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Metrics.radiusXL
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Metrics.radiusXL
        effect.layer?.masksToBounds = true
        return effect
    }()
    /// The grey the pointer brings. It sits over the glass and under the words, because a fill behind the glass
    /// wouldn't show.
    private let sheen = NSView()
    private let mark = StatusMark(size: 12)
    private let title = NSTextField(labelWithString: "")
    /// The list's name, shown when nothing else is in the row.
    private let heading = NSTextField(labelWithString: String(localized: "Projects"))
    private let segments = SummaryKind.allCases.map { SummarySegment($0) }
    private let row = NSStackView()
    private let card: SummaryCard
    private let app: AppModel
    private var asking = false
    private var counts = SummaryCounts(chats: [], done: [])
    /// Questions already shown or looked at. A question that isn't in this set lights the capsule as it comes in.
    private var seen: Set<String>?
    private var settleTimer: Timer?
    /// Moves the times in the counts forward by the minute.
    private(set) var tick: Timer?
    /// The rows to light in the list (SidebarController.light).
    var light: (Set<String>) -> Void = { _ in }
    private var lit = Set<String>()
    /// The count under the pointer.
    private var pointed: SummaryKind?
    /// The chats in each count at the last look. It is nil before the first look, because what's there at launch is no
    /// news.
    private var known: [SummaryKind: Set<String>]?
    /// Chats that just got into a count and wait their turn to be named. `peeking` is the chat named now.
    private var peeks: [(kind: SummaryKind, id: String)] = []
    private var peeking: (kind: SummaryKind, id: String)?
    private let peekEnd = Debounce()
    /// How long a count names the chat that just got there.
    private static let peekTime: TimeInterval = 4

    init(app: AppModel) {
        self.app = app
        card = SummaryCard(app: app)
        super.init(frame: .zero)
        title.maximumNumberOfLines = 1
        title.font = .ui(TextSize.row, weight: .semibold)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let content = NSStackView(views: [mark, title])
        content.spacing = Metrics.gap
        sheen.wantsLayer = true
        sheen.layer?.cornerRadius = Metrics.radiusXL
        sheen.layer?.cornerCurve = .continuous
        capsule.pin(glass)
        capsule.pin(sheen)
        content.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(content)
        capsule.look = { [weak self] hovering, pressed in
            self?.sheen.fadeBackground(to: pressed ? .fillSelected : hovering ? .fillHover : nil, held: pressed)
        }
        capsule.contextMenu = { [weak self] in self.map { Self.viewMenu($0.app) } }
        capsule.press = { [weak self] in self?.app.workbench.showNextNeedingAttention() }
        capsule.setAccessibilityElement(true)
        capsule.setAccessibilityRole(.button)
        heading.font = .ui(TextSize.caption, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        for segment in segments {
            segment.press = { [weak self, kind = segment.kind] in self?.pressed(kind) }
            segment.hover = { [weak self, weak segment] on in if let segment { self?.pointer(on, segment) } }
        }
        card.changed = { [weak self] in self?.relight() }
        for view in [capsule, heading] + segments as [NSView] { row.addArrangedSubview(view) }
        row.spacing = Metrics.lineGap
        row.setCustomSpacing(Metrics.gap, after: capsule)
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TextSize.of(24)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The row stops a gap short of Add Project.
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.gap),
            capsule.heightAnchor.constraint(equalToConstant: TextSize.of(24)),
            content.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -12)
        ])
        // Follow only what the row shows, so an agent's progress or title, which change a few times a second while it
        // works, don't redraw anything.
        track(owner: self) { [weak self, app] in
            SummaryShown(app, card: self?.card.kind)
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [app] in
            app.repos
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [app] in
            app.workbench.focusedTab
        } changed: { [weak self] _ in
            self?.update()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Lays out the row and drops what doesn't fit, in steps: first the time, then the words (a count keeps its
    /// number), then whole counts, starting with those that ask for nothing (`SummaryKind.dropOrder`). The counts for
    /// who needs you and who is working always stay. While a count names a chat, the other counts show only as numbers
    /// beside it. Everything stays a gap short of Add Project.
    override func layout() {
        super.layout()
        let capsuleWidth = asking ? title.intrinsicContentSize.width + 12 + Metrics.gap + 22 + Metrics.gap : 0
        let room = bounds.width - Metrics.gap - row.edgeInsets.left - capsuleWidth
        let peek = segments.first { $0.peek != nil }
        func width(_ set: [SummarySegment], _ level: Int) -> CGFloat {
            set.reduce(0) { $0 + $1.width(at: level) } + CGFloat(max(set.count - 1, 0)) * row.spacing
        }
        var kept = segments.filter { !counts[$0.kind].isEmpty }, level = peek == nil ? 0 : 2
        while width(kept, level) > room {
            if level < 2 {
                level += 1
                continue
            }
            let drop = SummaryKind.dropOrder.first { kind in kept.contains { $0.kind == kind && $0 !== peek } }
            guard let drop else { break }
            kept.removeAll { $0.kind == drop }
        }
        let others = width(kept.filter { $0 !== peek }, level) + (kept.count > 1 ? row.spacing : 0)
        peek?.fit(within: width(kept, level) > room ? max(room - others, 0) : nil)
        for segment in segments {
            if segment.level != level { segment.level = level }
            if segment.isHidden == kept.contains(segment) { segment.isHidden = !kept.contains(segment) }
        }
    }

    /// Hides the capsule once the last question is answered. It fades out before it gives its room to the counts.
    private func dismissCapsule() {
        guard window != nil, !Motion.reduced else { return capsule.isHidden = true }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            capsule.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // AppKit ends the group on the main thread
                guard let self, !self.asking else { return }
                self.capsule.isHidden = true
                self.capsule.alphaValue = 1
                self.needsLayout = true
            }
        }
    }

    func update() {
        let queue = AttentionQueue(app).sessions
        let inbox = Inbox.current(app, queue: queue)
        let shown = inbox.shown
        settleTimer = again(settleTimer, at: inbox.settlesAt)
        let questions = Set(inbox.queue.map(\.id)), new = shown.map(\.id).filter { !(seen ?? questions).contains($0) }
        seen = (seen ?? questions).union(shown.map(\.id)).union(inbox.viewing).intersection(questions)

        // The agent on screen still counts while it asks. When it is the only one asking, the capsule loses its glass
        // but keeps its number.
        let counted = inbox.counted, wasShown = !capsule.isHidden
        asking = !counted.isEmpty
        if asking, capsule.isHidden || capsule.alphaValue < 1 {
            capsule.fadeIn(Motion.base)   // fades in, or comes back while it was fading out
        } else if !asking, wasShown {
            dismissCapsule()
        }
        glass.isHidden = shown.isEmpty
        capsule.refreshPointer()   // after asking ends, no hover grey is left over
        mark.status = AgentStatus.mostUrgent(counted.map(\.shownStatus))
        mark.unread = true
        let said = String(localized: "\(counted.count) need you")
        if wasShown, asking, let was = Int(title.stringValue.prefix { $0.isNumber }), was != counted.count {
            title.roll(up: counted.count > was)
        }
        title.stringValue = said
        capsule.setAccessibilityLabel(String(localized: "Agents that need you: \(counted.count). Show the next one."))
        capsule.toolTip = String(localized: "Show the next agent that needs you (⇧⌘U)")
        if !new.isEmpty, !Motion.reduced {   // a question came in: a brief glow
            capsule.alphaValue = 0.4
            NSAnimationContext.runAnimationGroup {
                $0.duration = Motion.appear
                capsule.animator().alphaValue = 1
            }
        }

        counts = SummaryCounts(chats: app.sessions, done: queue)
        notice()
        let any = SummaryKind.allCases.contains { !counts[$0].isEmpty }
        for segment in segments {
            segment.say(counts.words(segment.kind))
            segment.peek = peekWords(segment.kind)
        }
        heading.isHidden = asking || any
        // When the counts are alone in the row, their words line up with the icons' column (a count's mark has its
        // own padding). Beside the capsule, they stand a step from it.
        row.edgeInsets.left = asking ? 0 : any ? Metrics.gapWide - Metrics.gap : Metrics.gapWide
        card.refresh(counts)
        relight()
        let timed = !counts[.working].isEmpty || !counts[.quiet].isEmpty
        let next = tick.map(\.fireDate).flatMap { $0 > Date() ? $0 : nil } ?? Date(timeIntervalSinceNow: 60)
        tick = again(tick, at: timed ? next : nil)
        needsLayout = true
    }

    /// Returns a timer that calls `update` at `date`, or none for a nil date. It returns `timer` itself when that timer
    /// is still set for the same time, in the future.
    private func again(_ timer: Timer?, at date: Date?) -> Timer? {
        if let timer, timer.isValid, timer.fireDate == date, timer.fireDate > Date() { return timer }
        timer?.invalidate()
        guard let date else { return nil }
        let next = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }   // the timer runs on the main run loop
        }
        RunLoop.main.add(next, forMode: .default)
        return next
    }

    private func segment(_ kind: SummaryKind) -> SummarySegment? { segments.first { $0.kind == kind } }

    /// Handles a click on a count. It goes to the chat the count names now, or else to the next chat it counts after
    /// the one on screen.
    private func pressed(_ kind: SummaryKind) {
        card.close()
        if let peeking, peeking.kind == kind {
            app.workbench.focus(session: peeking.id)
            return
        }
        let tab = app.workbench.focusedTab ?? ""
        let current = TabURI.scheme(tab) == "session" ? TabURI.body(tab) : nil
        guard let next = AttentionQueue.next(in: counts[kind], after: current) else { return NSSound.beep() }
        app.workbench.focus(session: next.id)
    }

    private func pointer(_ on: Bool, _ segment: SummarySegment) {
        if on {
            pointed = segment.kind
        } else if pointed == segment.kind {
            pointed = nil
        }
        card.hover(on ? segment : nil, counts)
        relight()
    }

    /// Lights the rows of the count under the pointer, or of the count whose card is up.
    private func relight() {
        let ids = (pointed ?? card.kind).map { Set(counts[$0].map(\.id)) } ?? []
        guard ids != lit else { return }
        lit = ids
        light(ids)
    }

    /// Queues the chats that got into a count since the last look, to be named in it. Only the finished and at-a-limit
    /// counts name chats.
    private func notice() {
        let named: [SummaryKind] = [.done, .limit]
        let now = Dictionary(uniqueKeysWithValues: named.map { ($0, Set(counts[$0].map(\.id))) })
        defer { known = now }
        if let peeking, now[peeking.kind]?.contains(peeking.id) != true { nextPeek() }   // seen, or it moved on
        guard let known else { return }
        for kind in named {
            let new = (now[kind] ?? []).filter { id in
                known[kind]?.contains(id) != true && !peeks.contains { $0.id == id }
            }
            peeks += new.map { (kind, $0) }
        }
        if peeking == nil { nextPeek() }
    }

    private func nextPeek() {
        peeking = nil
        peekEnd.cancel()
        while !peeks.isEmpty {
            let next = peeks.removeFirst()
            guard counts[next.kind].contains(where: { $0.id == next.id }) else { continue }
            peeking = next
            segment(next.kind)?.flash()
            peekEnd.after(Self.peekTime) { [weak self] in self?.endPeek() }
            return
        }
    }

    /// Ends the current peek when its time is up. If the pointer is on the count, it waits for the pointer to leave.
    private func endPeek() {
        if let peeking, segment(peeking.kind)?.hovering == true {
            peekEnd.after(1) { [weak self] in self?.endPeek() }
            return
        }
        nextPeek()
        update()
    }

    private func peekWords(_ kind: SummaryKind) -> (name: String, verb: String)? {
        guard let peeking, peeking.kind == kind, let session = app.session(peeking.id) else { return nil }
        let verb = kind == .done ? String(localized: "done") : String(localized: "at its limit")
        return (app.catalog.displayName(session), verb)
    }

    /// The capsule's menu: go to the agent that needs you, and pick what the second line on the rows says.
    static func viewMenu(_ app: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.add(String(localized: "Show Agent Needing You")) { app.workbench.showNextNeedingAttention() }
        menu.addItem(.separator())
        menu.addChoices(SettingKeys.agentDetail, app, heading: String(localized: "Second Line"))
        menu.addItem(.separator())
        menu.addSettingsLink(String(localized: "Needs You Settings…"), section: "appearance", group: "Sidebar", app)
        return menu
    }
}

/// What the row above the projects shows of the sessions: who is in each count and since when, and the chats on the
/// open card.
struct SummaryShown: Equatable {
    struct Entry: Equatable {
        let id: String, status: AgentStatus, since: Date, until: Date?
    }
    let queue: [Entry], counts: [[Entry]], card: [Session]

    @MainActor init(_ app: AppModel, card: SummaryKind?) {
        let attention = AttentionQueue(app).sessions
        let counts = SummaryCounts(chats: app.sessions, done: attention)
        func entry(_ session: Session, _ since: Date) -> Entry {
            Entry(id: session.id, status: session.shownStatus, since: since, until: session.continueAt)
        }
        queue = attention.map { entry($0, $0.statusAt ?? $0.createdAt) }
        self.counts = SummaryKind.allCases.map { kind in counts[kind].map { entry($0, SummaryCounts.since($0, kind)) } }
        self.card = card.map { counts[$0] } ?? []
    }
}

extension Inbox {
    /// Returns who needs you now. `shown` leaves out the agent on screen, because the capsule goes to the others, and
    /// `counted` keeps it.
    @MainActor static func current(_ app: AppModel, queue: [Session]) -> Inbox {
        // A finished agent keeps its mark in the row: it asks for nothing, so it isn't counted as needing you.
        var inbox = Inbox(queue: queue.filter { $0.shownStatus != .done })
        let tab = app.workbench.focusedTab ?? ""
        if TabURI.scheme(tab) == "session" { inbox.viewing = [TabURI.body(tab)] }
        return inbox
    }
}

/// The capsule that a click or VoiceOver presses. Under the pointer its glass greys a step (`look`), and one more step
/// while pressed, and a click makes it spring (`PointerControl`).
@MainActor
private final class Pressable: PointerControl {
    var press: () -> Void = {}
    var look: (_ hovering: Bool, _ pressed: Bool) -> Void = { _, _ in }
    var contextMenu: (() -> NSMenu?)?
    override func clicked() { press() }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func showPointer(hovering: Bool, pressed: Bool) { look(hovering, pressed) }
}
