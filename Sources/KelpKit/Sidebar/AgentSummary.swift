import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The row over the projects, beside Add Project. Who needs you is a glass capsule, which goes to the next one, as ⇧⌘U
/// does. Beside it each other count is a button of its own (`SummarySegment`): working, at a limit, quiet, done. A
/// click goes to the next chat it counts; the pointer resting on it shows them (`SummaryCard`) and lights their rows in
/// the list. A chat that just finished or hit its limit is named in its count for a few seconds. With nothing to count
/// (no project yet too) the row names the list under it. It keeps its place whatever it says: nothing in the list
/// moves.
@MainActor
final class AgentSummary: NSView {
    private let capsule = Pressable()
    /// Liquid Glass where there is (macOS 26): the one custom glass in the sidebar, over the list it floats above.
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
    /// Over the glass, under the words: the grey the pointer brings (a fill behind the glass wouldn't show).
    private let sheen = NSView()
    private let mark = StatusMark(size: 12)
    private let title = NSTextField(labelWithString: "")
    /// Alone in the row: the list's name.
    private let heading = NSTextField(labelWithString: String(localized: "Projects"))
    private let segments = SummaryKind.allCases.map { SummarySegment($0) }
    private let row = NSStackView()
    private let card: SummaryCard
    private let app: AppModel
    private var asking = false
    private var counts = SummaryCounts(chats: [], done: [])
    /// Questions already shown or looked at: one that isn't lights the capsule as it comes in.
    private var seen: Set<String>?
    private var settleTimer: Timer?
    /// The times in the counts move on by the minute.
    private var tick: Timer?
    /// The rows to light in the list (SidebarController.light).
    var light: (Set<String>) -> Void = { _ in }
    private var lit = Set<String>()
    /// The count under the pointer.
    private var pointed: SummaryKind?
    /// Who was in each count at the last look; nil before the first (what's there at launch is no news).
    private var known: [SummaryKind: Set<String>]?
    /// Chats that just got to a count, waiting their turn to be named, and the one named now.
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
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.gap),   // a gap short of Add Project
            capsule.heightAnchor.constraint(equalToConstant: TextSize.of(24)),
            content.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -12)
        ])
        track(owner: self) { [app] in
            app.sessions
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

    /// What doesn't fit goes in steps: the time, then the words (a count keeps its number), then whole counts, what
    /// asks for nothing first (`SummaryKind.dropOrder`). Who needs you and who works stay. While a count names a chat,
    /// the others stand as numbers beside it. All a gap short of Add Project.
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

    func update() {
        let inbox = Inbox.current(app)
        let shown = inbox.shown
        settleTimer?.invalidate()
        settleTimer = nil
        if let due = inbox.settlesAt {
            settleTimer = Timer.scheduledTimer(withTimeInterval: due.timeIntervalSinceNow, repeats: false) {
                [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.update() }
            }
        }
        let questions = Set(inbox.queue.map(\.id)), new = shown.map(\.id).filter { !(seen ?? questions).contains($0) }
        seen = (seen ?? questions).union(shown.map(\.id)).union(inbox.viewing).intersection(questions)

        // The agent on screen still counts while it asks; with only it asking the capsule loses its glass, not its number.
        let counted = inbox.counted
        asking = !counted.isEmpty
        capsule.isHidden = !asking
        glass.isHidden = shown.isEmpty
        capsule.refreshPointer()   // no longer asking: no grey left over from the pointer
        mark.status = AgentStatus.mostUrgent(counted.map(SidebarCell.shownStatus))
        mark.unread = true
        title.stringValue = String(localized: "\(counted.count) need you")
        capsule.setAccessibilityLabel(String(localized: "Agents that need you: \(counted.count). Show the next one."))
        capsule.toolTip = String(localized: "Show the next agent that needs you (⇧⌘U)")
        if !new.isEmpty, !Motion.reduced {   // a question came in: a brief glow
            capsule.alphaValue = 0.4
            NSAnimationContext.runAnimationGroup {
                $0.duration = Motion.appear
                capsule.animator().alphaValue = 1
            }
        }

        counts = SummaryCounts(chats: app.sessions, done: AttentionQueue(app).sessions)
        notice()
        let any = SummaryKind.allCases.contains { !counts[$0].isEmpty }
        for segment in segments {
            segment.say(counts.words(segment.kind))
            segment.peek = peekWords(segment.kind)
        }
        heading.isHidden = asking || any
        // Alone in the row the words stand in the icons' column (a count's mark has its own padding); beside the
        // capsule, a step from it.
        row.edgeInsets.left = asking ? 0 : any ? Metrics.gapWide - Metrics.gap : Metrics.gapWide
        card.refresh(counts)
        relight()
        tick?.invalidate()
        tick =
            counts[.working].isEmpty && counts[.quiet].isEmpty
            ? nil
            : Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.update() }
            }
        needsLayout = true
    }

    private func segment(_ kind: SummaryKind) -> SummarySegment? { segments.first { $0.kind == kind } }

    /// A click on a count: the chat it names now, else the next one it counts after the one on screen.
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

    /// The rows of the count under the pointer, or whose card is up.
    private func relight() {
        let ids = (pointed ?? card.kind).map { Set(counts[$0].map(\.id)) } ?? []
        guard ids != lit else { return }
        lit = ids
        light(ids)
    }

    /// Chats that got to a count since the last look wait their turn to be named in it: finished, or at a limit.
    private func notice() {
        let named: [SummaryKind] = [.done, .limit]
        let now = Dictionary(uniqueKeysWithValues: named.map { ($0, Set(counts[$0].map(\.id))) })
        defer { known = now }
        if let peeking, now[peeking.kind]?.contains(peeking.id) != true { nextPeek() }   // looked at, or went on
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

    /// Its time is up, unless the pointer is on it: then it waits for the pointer to go.
    private func endPeek() {
        if let peeking, segment(peeking.kind)?.hovering == true {
            peekEnd.after(1) { [weak self] in self?.endPeek() }
            return
        }
        nextPeek()
        update()
    }

    private func peekWords(_ kind: SummaryKind) -> (name: String, verb: String)? {
        guard let peeking, peeking.kind == kind, let s = app.session(peeking.id) else { return nil }
        let verb = kind == .done ? String(localized: "done") : String(localized: "at its limit")
        return (app.catalog.displayName(s), verb)
    }

    /// The capsule's: where who waits for you is, and what their rows say.
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

extension Inbox {
    /// Who needs you now; `shown` leaves out the agent on screen (the capsule goes to the others), `counted` keeps it.
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
