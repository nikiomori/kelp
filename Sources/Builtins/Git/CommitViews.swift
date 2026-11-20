// The views of the commit history: a commit's row with its badges, and the lane graph beside it.
import AppKit
import Core
import DesignKit
import KelpKit

/// A commit's row in the graph, two lines high: the subject over a caption line with its branch, its type, its age and
/// whether it is pushed. Its views are made once, and `show` sets everything it shows, because the outline hands a row
/// that scrolled away to the commit scrolling in.
final class CommitCell: NSTableCellView, Hoverable {
    static let id = NSUserInterfaceItemIdentifier("scm.commit")
    private let subject = NSTextField(labelWithString: ""), graph = GraphView()
    /// The grey "!" before the words of a breaking change ("feat!:").
    private let bang = NSTextField(labelWithString: "!")
    /// The caption line: the type, then the age ("fix · 11h ago").
    private let meta = NSTextField.label("", font: .uiDigits(TextSize.caption), color: .secondaryLabelColor)
    /// "· ↑ 5 not pushed" at the caption line's end, on the newest commit not pushed only: said once, not on each
    /// row. The arrow lands and pulses with pushes.
    private let up = NSImageView(), unpushed = NSStackView(), words = NSTextField(labelWithString: "")
    private let caption = NSStackView()
    private var badges: [NSView] = [], refs: [String]?
    private var graphWidth: NSLayoutConstraint?
    /// Counts the calls to `show`, so a landing or arrival timed for the commit shown before doesn't play on the next.
    private var shown = 0
    /// Called when the pointer came onto or left the row, so the commit's card follows it.
    var onHover: ((Bool) -> Void)?
    func setHover(_ on: Bool) { onHover?(on) }

    /// The height of a commit's row: two lines, as other two-line rows.
    static var lineHeight: CGFloat { TextSize.of(Metrics.rowTwoLine) }

    /// The hash of the row's commit, used to follow it across a rebuild.
    private(set) var commitHash = ""
    init() {
        super.init(frame: .zero)
        identifier = Self.id
        graph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(graph)
        subject.textColor = .labelColor
        subject.lineBreakMode = .byTruncatingTail
        subject.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        bang.font = .ui(TextSize.row, weight: .semibold)
        bang.textColor = .secondaryLabelColor   // a kind of commit, not a failure: grey, its weight keeps it apart
        bang.setAccessibilityLabel(String(localized: "Breaking change"))
        bang.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The type and age give way first, so "not pushed", which is state, stays in sight.
        meta.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        up.image = .symbol("arrow.up", String(localized: "Not pushed yet"))
        up.symbolConfiguration = .chrome(Metrics.iconTiny)
        up.contentTintColor = .secondaryLabelColor
        let dot = NSTextField.label("·", font: .ui(TextSize.caption), color: .secondaryLabelColor)
        words.font = .ui(TextSize.caption)
        words.textColor = .secondaryLabelColor
        for view in [dot, up, words] as [NSView] {
            view.setContentCompressionResistancePriority(.init(260), for: .horizontal)
            unpushed.addArrangedSubview(view)
        }
        unpushed.spacing = 2
        unpushed.setCustomSpacing(Metrics.gap - 2, after: dot)
        unpushed.toolTip = String(localized: "Not pushed yet")
        for view in [meta, unpushed, NSView()] { caption.addArrangedSubview(view) }
        caption.spacing = Metrics.gap - 2
        let title = NSStackView(views: [bang, subject])
        title.spacing = 2
        let lines = NSStackView(views: [title, caption])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Metrics.lineGap
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        let width = graph.widthAnchor.constraint(equalToConstant: 0)
        graphWidth = width
        NSLayoutConstraint.activate([
            graph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GraphView.leading),
            graph.topAnchor.constraint(equalTo: topAnchor),
            graph.bottomAnchor.constraint(equalTo: bottomAnchor), width,
            lines.leadingAnchor.constraint(equalTo: graph.trailingAnchor, constant: 2),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: lines.widthAnchor),
            caption.widthAnchor.constraint(equalTo: lines.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `pushed` is nil without a remote; `unpushedCount` is given to the newest commit not pushed, which says how
    /// many. A commit that just reached the remote (`landsAfter`) starts as it was and lands after that many seconds.
    func show(
        _ commit: GraphCommit, graphWidth width: CGFloat, isHead: Bool, pushed: Bool?, unpushedCount: Int? = nil,
        landsAfter delay: Double? = nil, arrivesAfter arrival: Double? = nil
    ) {
        shown += 1
        let ticket = shown, parsedSubject = CommitSubject(commit.subject), notPushed = pushed == false
        commitHash = commit.hash
        settle()
        if let arrival, !Motion.reduced {
            alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.settle + arrival) { [weak self] in
                if self?.shown == ticket { self?.arrive() }
            }
        }
        graph.commit = commit
        graph.isHead = isHead
        graph.needsDisplay = true
        graphWidth?.constant = width
        subject.stringValue = parsedSubject.text
        subject.font = .ui(TextSize.row, weight: isHead ? .medium : .regular)   // 600 is kept for news
        bang.isHidden = !parsedSubject.breaking
        meta.stringValue = [Self.kind(parsedSubject, merge: commit.parents.count > 1), Self.relative(commit.date)]
            .compactMap { $0 }.joined(separator: " · ")
        unpushed.isHidden = unpushedCount == nil
        if let unpushedCount { words.stringValue = String(localized: "\(unpushedCount) not pushed") }
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.settle + delay) { [weak self] in
                if self?.shown == ticket { self?.land() }
            }
        }
        showBadges(commit.refs)
        // A branch's chip and "↑ 4 not pushed" fill the line: the type and age, in the card, would only show as "…".
        meta.isHidden = unpushedCount != nil && !commit.refs.isEmpty
        // The card (CommitCard) shows all this to the pointer, and VoiceOver reads it here.
        let when = Date(timeIntervalSince1970: commit.date).formatted(date: .abbreviated, time: .shortened)
        setAccessibilityHelp(
            "\(commit.subject)\n\n\(commit.author) · \(when)\n\(commit.hash.prefix(10))"
                + (commit.refs.isEmpty ? "" : "\n" + commit.refs.joined(separator: ", "))
                + (notPushed ? "\n" + String(localized: "Not pushed yet") : ""))
    }

    /// The caption's word for the commit's type: "fix", "merge" for a merge with no type, and nil for a
    /// plain subject.
    static func kind(_ commitSubject: CommitSubject, merge: Bool) -> String? {
        commitSubject.type ?? (merge ? "merge" : nil)   // the scope is in the card: the row keeps to the type
    }

    /// Stops what the row did for the commit it showed before: its arrival, or its arrow's landing or pulse.
    private func settle() {
        alphaValue = 1
        layer?.removeAllAnimations()
        up.removeAllSymbolEffects()
        unpushed.layer?.removeAnimation(forKey: "land")
        unpushed.alphaValue = 1
    }

    /// The branch or tag leads the caption line.
    private func showBadges(_ refs: [String]) {
        guard refs != self.refs else { return }
        self.refs = refs
        badges.forEach { $0.removeFromSuperview() }
        badges = Self.badges(refs)
        for (index, badge) in badges.enumerated() { caption.insertArrangedSubview(badge, at: index) }
    }

    /// A commit new in the graph comes in from above its place, which is where new commits come from.
    private func arrive() {
        slide(from: NSPoint(x: placeInWindow.x, y: placeInWindow.y + Self.lineHeight))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.appear
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Pulses the arrows of the commits on their way while the push runs.
    func pulse(_ on: Bool) {
        guard !unpushed.isHidden else { return }
        if on, !Motion.reduced { up.addSymbolEffect(.pulse, options: .repeating) } else { up.removeAllSymbolEffects() }
    }

    /// When the commit just reached the remote, its arrow hops up and "not pushed" fades.
    private func land() {
        guard !Motion.reduced else {
            unpushed.alphaValue = 0
            return
        }   // with reduced motion, there is no hop and no fade
        up.addSymbolEffect(.bounce.up)
        unpushed.wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + Motion.fast
        fade.duration = Motion.appear
        fade.fillMode = .backwards
        unpushed.layer?.add(fade, forKey: "land")
        unpushed.alphaValue = 0
    }

    /// The commit's type as an SF Symbol, drawn in the secondary label colour: the shape names the type, and colour
    /// stays for state. A merge without a type gets git's merge mark, and any other subject gets none.
    static func mark(_ commitSubject: CommitSubject, merge: Bool) -> String? {
        switch commitSubject.type {
        case "feat": "sparkle"
        case "fix": "ladybug"
        case "refactor": "arrow.triangle.2.circlepath"
        case "perf": "bolt"
        case "docs": "doc.text"
        case "test": "flask"
        case "build", "ci": "hammer"
        case "chore": "wrench.adjustable"
        case "style": "paintbrush"
        case "revert": "arrow.uturn.backward"
        default: merge ? "arrow.triangle.merge" : nil
        }
    }

    /// The first branch or tag, then how many more (their names in its tooltip).
    static func badges(_ refs: [String]) -> [NSView] {
        let out = labels(refs)
        var views: [NSView] = out.prefix(1).map { Badge(text: $0.0, color: $0.1, strong: $0.2) }
        if out.count > 1 {
            let more = Badge(text: "+\(out.count - 1)", color: .secondaryLabelColor, strong: false)
            more.toolTip = out.dropFirst().map(\.0).joined(separator: "\n")
            views.append(more)
        }
        return views
    }

    /// Local branches and tags (HEAD's branch first). A remote ref shows only when there is no local branch of that
    /// name. The branches in `emphasis` are drawn stronger, because with Graphite the accent's grey was the remote's
    /// and "main" read as "origin/main".
    static func labels(_ refs: [String]) -> [(String, NSColor, Bool)] {
        var out: [(String, NSColor, Bool)] = []
        let locals = Set(
            refs.compactMap { r -> String? in
                if r.hasPrefix("HEAD -> ") { return String(r.dropFirst(8)) }
                return r.hasPrefix("tag: ") || r.contains("/") || r == "HEAD" ? nil : r
            })
        for ref in refs where !ref.hasSuffix("/HEAD") {   // origin/HEAD only repeats origin/main
            if ref.hasPrefix("HEAD -> ") {
                out.insert((String(ref.dropFirst(8)), .emphasis, true), at: 0)
            } else if ref == "HEAD" {
                out.insert(("HEAD", .emphasis, true), at: 0)
            } else if ref.hasPrefix("tag: ") {
                out.append((String(ref.dropFirst(5)), .secondaryLabelColor, false))   // orange is for what waits for you
            } else if ref.contains("/") {
                if !locals.contains(String(ref.drop { $0 != "/" }.dropFirst())) {
                    out.append((ref, .secondaryLabelColor, false))
                }
            } else {
                out.append((ref, .emphasis, false))
            }
        }
        return out
    }

    /// "now", "4m ago", "2h ago", "3d ago" in the user's language, and a date from a week back.
    static func relative(_ seconds: Double) -> String {
        let age = Date().timeIntervalSince1970 - seconds
        switch age {
        case ..<60: return String(localized: "now")
        case ..<(86400 * 7): return String(localized: "\(shortSpan(age)) ago")
        default:
            let date = Date(timeIntervalSince1970: seconds)
            let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            return sameYear
                ? date.formatted(.dateTime.month(.abbreviated).day())
                : date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

/// A small rounded label for a branch or tag.
final class Badge: NSView {
    private let text: NSAttributedString
    private let color: NSColor
    init(text: String, color: NSColor, strong: Bool) {
        self.color = color
        let middle = NSMutableParagraphStyle()
        middle.lineBreakMode = .byTruncatingMiddle   // a branch is cut in the middle, as Finder cuts a name
        self.text = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.ui(TextSize.micro, weight: strong ? .semibold : .medium),
                .foregroundColor: color, .paragraphStyle: middle
            ])
        super.init(frame: .zero)
        setContentCompressionResistancePriority(.init(300), for: .horizontal)
        toolTip = text
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The chip grows with Text size, as the words in it do.
    override var intrinsicContentSize: NSSize {
        NSSize(width: min(ceil(text.size().width) + 2 * Metrics.gap, 110), height: TextSize.of(16))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.fillTint(color).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusXS, yRadius: Metrics.radiusXS).fill()
        let width = bounds.width - 2 * Metrics.gap
        text.draw(
            with: NSRect(
                x: Metrics.gap, y: (bounds.height - text.size().height) / 2, width: width, height: text.size().height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// One row of the history graph: lines from the row above to the dot, and from the dot to the row below.
final class GraphView: NSView {
    static let maxLanes = 6
    static let step: CGFloat = 11, inset: CGFloat = 7
    /// Where a commit's graph starts in its row: at the panel's inset, so the subjects start under the section's title.
    static let leading = Metrics.inset
    static let colors: [NSColor] = [
        .systemBlue, .systemPurple, .systemOrange, .systemTeal, .systemPink, .systemGreen, .systemIndigo, .systemBrown
    ]
    static func width(lanes: Int) -> CGFloat { inset * 2 + CGFloat(max(lanes, 1) - 1) * step }
    static func x(_ lane: Int) -> CGFloat { inset + CGFloat(lane) * step }
    static func color(_ lane: Int) -> NSColor { colors[lane % colors.count] }

    var commit: GraphCommit?
    var isHead = false
    /// Under an expanded commit, only these lanes are drawn, straight down.
    var through: [Int]?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let through {
            for lane in through {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: Self.x(lane), y: 0))
                path.line(to: NSPoint(x: Self.x(lane), y: bounds.height))
                path.lineWidth = 1.5
                Self.color(lane).setStroke()
                path.stroke()
            }
            return
        }
        guard let commit else { return }
        let mid = bounds.height / 2
        func segment(_ lanes: [Int], from y0: CGFloat, to y1: CGFloat, color: NSColor) {
            guard lanes.count == 2 else { return }
            let x0 = Self.x(lanes[0]), x1 = Self.x(lanes[1]), path = NSBezierPath()
            path.move(to: NSPoint(x: x0, y: y0))
            if x0 == x1 {
                path.line(to: NSPoint(x: x1, y: y1))
            } else {
                path.curve(
                    to: NSPoint(x: x1, y: y1), controlPoint1: NSPoint(x: x0, y: (y0 + y1) / 2),
                    controlPoint2: NSPoint(x: x1, y: (y0 + y1) / 2))
            }
            path.lineWidth = 1.5
            color.setStroke()
            path.stroke()
        }
        for l in commit.top { segment(l, from: 0, to: mid, color: Self.color(l[0])) }
        for lanes in commit.bottom {
            segment(lanes, from: mid, to: bounds.height, color: Self.color(lanes.count == 2 ? lanes[1] : commit.lane))
        }
        let center = Self.x(commit.lane), col = Self.color(commit.lane)
        if isHead {
            let ring = NSBezierPath(ovalIn: NSRect(x: center - 4.5, y: mid - 4.5, width: 9, height: 9))
            NSColor.windowBackgroundColor.setFill()
            ring.fill()
            ring.lineWidth = 2
            col.setStroke()
            ring.stroke()
        } else {
            col.setFill()
            NSBezierPath(ovalIn: NSRect(x: center - 3.5, y: mid - 3.5, width: 7, height: 7)).fill()
        }
    }
}
