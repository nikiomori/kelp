import AppKit
import Core
import WorkbenchKit

/// Needs You as tabs (Appearance › Sidebar › Needs You): over the projects, a zone with a row for each agent that needs
/// you (its project's icon, its name, when, its mark), so who waits is seen even when its row is scrolled away or its
/// project folded. A click opens the agent, which then leaves the zone. Six rows at most: past that the last says
/// "N more" and goes to the next one, as ⇧⌘U does. The heading ("Needs You 3") never changes height; its chevron folds
/// the zone to it, kept across launches. The zone hangs over the top of the list, which is inset by as much: no project
/// moves when one comes or goes. It is the sidebar's glass here (the capsule isn't shown); a new question lights the
/// heading. Nothing needs you: how many work. Nobody working either: the heading goes.
@MainActor
final class NeedsYouZone: NSView {
    /// The heading's place in the layout: the list starts under it, the agents hang over the list.
    let line = NSLayoutGuide()
    /// The list the agents hang over: what they cover can be scrolled out from under them.
    weak var list: NSScrollView? { didSet { update() } }
    private static let most = 6
    private static let foldedKey = "sidebar.needsYouFolded"
    private let rows = (0..<NeedsYouZone.most).map { _ in Row() }
    /// Glass where there is (macOS 26), else a popover-material card.
    private let glass: NSView = {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 10
            return g
        }
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .withinWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true
        return v
    }()
    private let header = Pressable()
    private let mark = StatusMark(size: 11)   // nothing needs you: the working one's
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var height: NSLayoutConstraint?, lineHeight: NSLayoutConstraint?
    private let app: AppModel
    private var shown: [Session] = []
    /// Questions already shown or looked at: one that isn't lights the heading as it comes in.
    private var seen: Set<String>?
    private var folded = UserDefaults.standard.bool(forKey: NeedsYouZone.foldedKey)
    private var settleTimer: Timer?
    /// After each update: who needs you may have changed (Automatic looks whether they are all in view).
    var updated: () -> Void = {}

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        header.wantsLayer = true; header.layer?.cornerRadius = 10
        title.lineBreakMode = .byTruncatingTail; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .uiDigits(11, weight: .semibold); count.textColor = .labelColor
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold); chevron.contentTintColor = .secondaryLabelColor
        header.setAccessibilityElement(true)
        header.press = { [weak self] in self?.fold() }
        let heading = NSStackView(views: [mark, title, NSView(), count, chevron])
        heading.spacing = 6
        heading.detachesHiddenViews = true
        addLayoutGuide(line)
        for x in [glass, header] + rows { x.translatesAutoresizingMaskIntoConstraints = false; addSubview(x) }
        heading.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(heading)
        let h = heightAnchor.constraint(equalToConstant: 0), lh = line.heightAnchor.constraint(equalToConstant: 0)
        height = h; lineHeight = lh
        var all = [h, lh, line.topAnchor.constraint(equalTo: topAnchor),
                   line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
                   header.topAnchor.constraint(equalTo: line.topAnchor), header.bottomAnchor.constraint(equalTo: line.bottomAnchor),
                   header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                   heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
                   heading.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
                   heading.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                   glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
                   glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)]
        for (i, r) in rows.enumerated() {   // one under another; a hidden one is 0 high
            all += [r.topAnchor.constraint(equalTo: i == 0 ? line.bottomAnchor : rows[i - 1].bottomAnchor),
                    r.leadingAnchor.constraint(equalTo: leadingAnchor), r.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)]
        }
        NSLayoutConstraint.activate(all)
        track(owner: self) { [app] in app.sessions } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app] in app.workbench.focusedTab } changed: { [weak self] _ in self?.update() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        let inbox = Inbox.current(app)
        shown = inbox.shown
        settleTimer?.invalidate(); settleTimer = nil
        if let due = inbox.settlesAt {
            settleTimer = Timer.scheduledTimer(withTimeInterval: due.timeIntervalSinceNow, repeats: false) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.update() }
            }
        }
        let agents = app.sessions.filter { $0.agent != "shell" && $0.status != .exited }
        let asks = { (s: Session) in SidebarCell.shownStatus(s) != .done }
        let asking = shown.filter(asks)
        let questions = Set(inbox.queue.filter(asks).map(\.id))
        let new = seen.map { s in asking.filter { !s.contains($0.id) }.map(\.id) } ?? []
        seen = (seen ?? questions).union(asking.map(\.id)).union(inbox.viewing).intersection(questions)

        let busy = agents.filter { $0.status == .working }.count
        isHidden = busy == 0 && shown.isEmpty   // nothing to say: no empty band over the list
        // Past six, five agents and "N more" in the sixth row.
        let n = folded ? 0 : min(shown.count, Self.most), agentsShown = shown.count > Self.most ? Self.most - 1 : n
        let row = TextSize.of(28), hang = n == 0 ? 0 : row * CGFloat(n) + 4
        lineHeight?.constant = isHidden ? 0 : TextSize.of(28); height?.constant = isHidden ? 0 : TextSize.of(28) + hang
        hangOver(hang)
        glass.isHidden = shown.isEmpty

        chevron.isHidden = shown.isEmpty; count.isHidden = shown.isEmpty
        chevron.image = .symbol(folded ? "chevron.right" : "chevron.down")
        header.toolTip = shown.isEmpty ? nil : folded ? String(localized: "Expand") : String(localized: "Collapse")
        if shown.isEmpty {
            mark.status = busy > 0 ? .working : nil; mark.isHidden = busy == 0
            title.attributedStringValue = NSAttributedString(string: busy > 0 ? String(localized: "\(busy) working") : "",
                                                             attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.secondaryLabelColor])
            header.setAccessibilityRole(.staticText)
            header.setAccessibilityLabel(title.stringValue)
        } else {
            mark.isHidden = true
            let heading: [NSAttributedString.Key: Any] = [.font: NSFont.ui(11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
            title.attributedStringValue = NSAttributedString(string: String(localized: "Needs You"), attributes: heading)
            count.stringValue = "\(shown.count)"
            header.setAccessibilityRole(.button)
            header.setAccessibilityLabel(String(localized: "\(shown.count) need you") + ", " + (header.toolTip ?? ""))
        }

        for (i, r) in rows.enumerated() {
            r.isHidden = i >= n; r.height.constant = i < n ? row : 0
            guard i < n else { continue }
            if i >= agentsShown {
                r.more(shown.count - agentsShown) { [app] in app.workbench.showNextNeedingAttention() }
                continue
            }
            let s = shown[i]
            r.show(s, app: app) { [app] in app.workbench.focus(session: s.id) }
            if new.contains(s.id), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                r.alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.3; r.animator().alphaValue = 1 }
            }
        }
        if !new.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { flash() }
        updated()
    }

    /// The chevron: the zone down to its heading, or open again; kept across launches.
    private func fold() {
        guard !shown.isEmpty else { return }
        folded.toggle(); UserDefaults.standard.set(folded, forKey: Self.foldedKey)
        update()
    }

    /// A question came in: the heading lights up and fades back.
    private func flash() {
        var from = NSColor.labelColor.withAlphaComponent(0.3).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { from = NSColor.labelColor.withAlphaComponent(0.3).cgColor }
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.fromValue = from; a.toValue = NSColor.clear.cgColor
        a.duration = 1.2; a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        header.layer?.add(a, forKey: "flash")
    }

    /// The rows under the agents keep their place: the list is inset by what hangs over it, without scrolling.
    private func hangOver(_ h: CGFloat) {
        guard let list, list.contentInsets.top != h else { return }
        let clip = list.contentView, y = clip.bounds.origin.y
        list.contentInsets.top = h
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(y, -h)))
        list.reflectScrolledClipView(clip)
    }
    override func scrollWheel(with e: NSEvent) { list?.scrollWheel(with: e) }   // it lies over the list: scrolling it is scrolling that
}

extension Inbox {
    /// Who needs you now: the agent on screen isn't counted.
    @MainActor static func current(_ app: AppModel) -> Inbox {
        var inbox = Inbox(queue: AttentionQueue(app).sessions)
        let tab = app.workbench.focusedTab ?? ""
        if TabURI.scheme(tab) == "session" { inbox.viewing = [TabURI.body(tab)] }
        return inbox
    }
}

/// A view a click or VoiceOver presses.
@MainActor
private class Pressable: NSView {
    var press: () -> Void = {}
    override func mouseDown(with e: NSEvent) { press() }
    override func accessibilityPerformPress() -> Bool { press(); return true }
}

/// One agent in the zone: its project's icon, its name, when, its mark.
@MainActor
private final class Row: Pressable {
    private let project = NSImageView(), mark = StatusMark(size: 12)
    private let name = NSTextField(labelWithString: ""), ago = NSTextField(labelWithString: "")
    var height: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.usesSingleLineMode = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ago.font = .uiDigits(11); ago.textColor = .secondaryLabelColor
        ago.setContentHuggingPriority(.required, for: .horizontal); ago.setContentCompressionResistancePriority(.required, for: .horizontal)
        for x in [project, name, ago, mark] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; addSubview(x) }
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            project.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), project.centerYAnchor.constraint(equalTo: centerYAnchor),
            project.widthAnchor.constraint(equalToConstant: 16), project.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: project.trailingAnchor, constant: 6), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            ago.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6), ago.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            mark.leadingAnchor.constraint(equalTo: ago.trailingAnchor, constant: 6), mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: Session, app: AppModel, press: @escaping () -> Void) {
        let repo = app.repo(app.worktree(s.worktreeId)?.repoId)
        if let repo { ProjectIcon.show(repo.path, in: project, app: app) } else { project.image = nil }
        for v in [project, ago, mark] as [NSView] { v.isHidden = false }
        name.stringValue = app.catalog.displayName(s)
        name.font = .ui(13, weight: .semibold); name.textColor = .labelColor
        ago.stringValue = shortAgo(s.statusAt ?? s.createdAt)
        mark.status = SidebarCell.shownStatus(s); mark.unread = true   // read or not, it's here to be seen
        let what = SidebarCell.askLine(s, mode: "always").map { [$0.prefix?.0, $0.text].compactMap { $0 }.joined(separator: " ") }
        toolTip = what
        setAccessibilityLabel([name.stringValue, what, repo?.name, ago.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        self.press = press
    }

    /// The sixth row, past six: how many more, going to the next one.
    func more(_ n: Int, press: @escaping () -> Void) {
        for v in [project, ago, mark] as [NSView] { v.isHidden = true }
        name.stringValue = String(localized: "\(n) more")
        name.font = .ui(12); name.textColor = .secondaryLabelColor
        toolTip = String(localized: "Show the next agent that needs you (⇧⌘U)")
        setAccessibilityLabel(name.stringValue + ". " + (toolTip ?? ""))
        self.press = press
    }
}
