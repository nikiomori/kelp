// The commit history's views: a commit's row with its badges, and the lane graph beside it.
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

final class CommitCell: NSTableCellView, Hoverable {
    private let subject: NSTextField, up = NSImageView()
    /// The pointer came onto or left the row: the commit's card follows it.
    var onHover: ((Bool) -> Void)?
    func setHover(_ on: Bool) { onHover?(on) }

    /// The commit's line; its branch or tag leads it, right after its dot.
    static var lineHeight: CGFloat { TextSize.of(Metrics.row) }

    /// `pushed` is nil without a remote; a commit not pushed yet has an arrow before its time.
    /// A commit that just reached the remote (`landsAfter`) starts as it was and lands after that many seconds.
    /// The scope, while the row can spare it: in a narrow panel the subject keeps the room.
    private var scopeLabel: NSTextField?
    override func layout() {
        scopeLabel?.isHidden = bounds.width < TextSize.of(340)
        super.layout()
    }

    /// A commit's row, for following it across a rebuild.
    let commitHash: String
    init(
        _ c: GraphCommit, graphWidth: CGFloat, isHead: Bool, pushed: Bool?, landsAfter delay: Double? = nil,
        arrivesAfter arrival: Double? = nil
    ) {
        let parsedSubject = CommitSubject(c.subject)
        subject = NSTextField(labelWithString: parsedSubject.text)
        commitHash = c.hash
        super.init(frame: .zero)
        if let arrival, !Motion.reduced {
            alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.settle + arrival) { [weak self] in self?.arrive() }
        }
        let unpushed = pushed == false
        let graph = GraphView()
        graph.commit = c
        graph.isHead = isHead
        graph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(graph)
        subject.font = .ui(TextSize.row, weight: isHead ? .semibold : .regular)
        subject.textColor = .labelColor
        subject.lineBreakMode = .byTruncatingTail
        subject.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        // A breaking change ("feat!:"): a red "!" before the words.
        let bang = parsedSubject.breaking ? NSTextField(labelWithString: "!") : nil
        bang?.font = .ui(TextSize.row, weight: .bold)
        bang?.textColor = .textRed
        bang?.setAccessibilityLabel(String(localized: "Breaking change"))
        let mark = Self.mark(parsedSubject, merge: c.parents.count > 1).map { typeMark in
            let markView = NSImageView(
                image: .symbol(typeMark.symbol, parsedSubject.type ?? String(localized: "Merge commit")))
            // One colour in the list, so the subjects lead; the card under the pointer shows the type's own.
            markView.symbolConfiguration = .chrome(Metrics.iconSmall)
            markView.contentTintColor = .secondaryLabelColor
            markView.widthAnchor.constraint(equalToConstant: 13).isActive = true
            return markView
        }
        let scope = NSTextField(labelWithString: parsedSubject.scope ?? "")
        scope.font = .ui(TextSize.caption)
        scope.textColor = .secondaryLabelColor
        scope.lineBreakMode = .byTruncatingTail
        scope.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        scope.widthAnchor.constraint(lessThanOrEqualToConstant: TextSize.of(80)).isActive = true
        let date = NSTextField(labelWithString: Self.relative(c.date))
        date.font = .uiDigits(TextSize.caption)
        date.textColor = .secondaryLabelColor
        // Not on the remote yet: an arrow before the time, as in GitHub Desktop.
        let notPushed = String(localized: "Not pushed yet")
        up.image = .symbol("arrow.up", notPushed)
        up.symbolConfiguration = .chrome(Metrics.iconTiny)
        up.contentTintColor = .secondaryLabelColor
        up.toolTip = notPushed
        up.isHidden = !unpushed && delay == nil
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.settle + delay) { [weak self] in self?.land() }
        }
        // A row with a branch or tag leaves out the scope: the badge says where the commit is, the words keep their room.
        let badges = Self.badges(c.refs)
        scope.isHidden = !badges.isEmpty
        scopeLabel = badges.isEmpty ? scope : nil
        let row = NSStackView(views: badges + [mark, bang, subject].compactMap { $0 } + [NSView(), scope, up, date])
        row.spacing = Metrics.gap
        row.alignment = .centerY
        if let bang { row.setCustomSpacing(2, after: bang) }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            graph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GraphView.leading),
            graph.topAnchor.constraint(equalTo: topAnchor),
            graph.bottomAnchor.constraint(equalTo: bottomAnchor),
            graph.widthAnchor.constraint(equalToConstant: graphWidth),
            row.leadingAnchor.constraint(equalTo: graph.trailingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor), row.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        ])
        // The card (CommitCard) shows all this to the pointer; VoiceOver reads it here.
        let when = Date(timeIntervalSince1970: c.date).formatted(date: .abbreviated, time: .shortened)
        setAccessibilityHelp(
            "\(c.subject)\n\n\(c.author) · \(when)\n\(c.hash.prefix(10))"
                + (c.refs.isEmpty ? "" : "\n" + c.refs.joined(separator: ", "))
                + (unpushed ? "\n" + notPushed : ""))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// New in the graph: it comes in from above its place, where new commits come from.
    private func arrive() {
        slide(from: NSPoint(x: placeInWindow.x, y: placeInWindow.y + Metrics.row))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.appear
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// While the push runs, the arrows of the commits on their way pulse.
    func pulse(_ on: Bool) {
        guard !up.isHidden else { return }
        if on, !Motion.reduced { up.addSymbolEffect(.pulse, options: .repeating) } else { up.removeAllSymbolEffects() }
    }

    /// Just reached the remote: the arrow hops up and fades.
    private func land() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            up.alphaValue = 0
            return
        }   // no hop, no fade
        up.addSymbolEffect(.bounce.up)
        up.wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + Motion.fast
        fade.duration = Motion.appear
        fade.fillMode = .backwards
        up.layer?.add(fade, forKey: "land")
        up.alphaValue = 0
    }

    /// The commit's type as an SF Symbol; the colour repeats the shape, it never stands alone. A merge without a type
    /// gets git's merge mark; any other subject none.
    static func mark(_ s: CommitSubject, merge: Bool) -> (symbol: String, color: NSColor)? {
        switch s.type {
        case "feat": ("sparkle", .systemGreen)
        case "fix": ("ladybug", .systemOrange)
        case "refactor": ("arrow.triangle.2.circlepath", .systemPurple)
        case "perf": ("bolt", .systemYellow)
        case "docs": ("doc.text", .systemCyan)
        case "test": ("flask", .systemIndigo)
        case "build", "ci": ("hammer", .secondaryLabelColor)
        case "chore": ("wrench.adjustable", .secondaryLabelColor)
        case "style": ("paintbrush", .systemPink)
        case "revert": ("arrow.uturn.backward", .systemRed)
        default: merge ? ("arrow.triangle.merge", .secondaryLabelColor) : nil
        }
    }

    /// The first branch or tag, then how many more (their names in its tooltip): in the commit's line, they leave the
    /// words their room.
    static func badges(_ refs: [String]) -> [NSView] {
        let out = labels(refs)
        var views: [NSView] = out.prefix(1).map {
            let badge = Badge(text: $0.0, color: $0.1, strong: $0.2)
            badge.widthAnchor.constraint(lessThanOrEqualToConstant: 60).isActive = true   // a long name ends in "…", the subject keeps its room
            return badge
        }
        if out.count > 1 {
            let more = Badge(text: "+\(out.count - 1)", color: .secondaryLabelColor, strong: false)
            more.toolTip = out.dropFirst().map(\.0).joined(separator: "\n")
            views.append(more)
        }
        return views
    }

    /// Local branches and tags (HEAD's branch first); a remote ref shows only when no local branch of that name is here.
    /// The branches in `emphasis`: with Graphite the accent's grey was the remote's, and "main" read as "origin/main".
    static func labels(_ refs: [String]) -> [(String, NSColor, Bool)] {
        var out: [(String, NSColor, Bool)] = []
        let locals = Set(
            refs.compactMap { r -> String? in
                if r.hasPrefix("HEAD -> ") { return String(r.dropFirst(8)) }
                return r.hasPrefix("tag: ") || r.contains("/") || r == "HEAD" ? nil : r
            })
        for r in refs where !r.hasSuffix("/HEAD") {   // origin/HEAD only repeats origin/main
            if r.hasPrefix("HEAD -> ") {
                out.insert((String(r.dropFirst(8)), .emphasis, true), at: 0)
            } else if r == "HEAD" {
                out.insert(("HEAD", .emphasis, true), at: 0)
            } else if r.hasPrefix("tag: ") {
                out.append((String(r.dropFirst(5)), .systemOrange, false))
            } else if r.contains("/") {
                if !locals.contains(String(r.drop { $0 != "/" }.dropFirst())) {
                    out.append((r, .secondaryLabelColor, false))
                }
            } else {
                out.append((r, .emphasis, false))
            }
        }
        return out
    }

    static func relative(_ t: Double) -> String {
        let age = Date().timeIntervalSince1970 - t
        switch age {
        case ..<(86400 * 7): return shortAgo(Date(timeIntervalSince1970: t))   // "now", "4m", "2h", "3d" in the user's language
        default:
            let date = Date(timeIntervalSince1970: t)
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
        self.text = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.ui(TextSize.micro, weight: strong ? .semibold : .medium),
                .foregroundColor: color
            ])
        super.init(frame: .zero)
        setContentCompressionResistancePriority(.init(300), for: .horizontal)
        toolTip = text
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: min(ceil(text.size().width) + 10, 110), height: 16) }
    override func draw(_ r: NSRect) {
        color.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusXS, yRadius: Metrics.radiusXS).fill()
        let width = bounds.width - 10
        text.draw(
            with: NSRect(x: 5, y: (bounds.height - text.size().height) / 2, width: width, height: text.size().height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// One row of the history graph: lines from the row above to the dot, from the dot to the row below.
final class GraphView: NSView {
    static let maxLanes = 6
    static let step: CGFloat = 11, inset: CGFloat = 7
    /// Where a commit's graph starts in its row: the panel's inset, so the subjects start under the section's title.
    static let leading = Metrics.inset
    static let colors: [NSColor] = [
        .systemBlue, .systemPurple, .systemOrange, .systemTeal, .systemPink, .systemGreen, .systemIndigo, .systemBrown
    ]
    static func width(lanes: Int) -> CGFloat { inset * 2 + CGFloat(max(lanes, 1) - 1) * step }
    static func x(_ lane: Int) -> CGFloat { inset + CGFloat(lane) * step }
    static func color(_ lane: Int) -> NSColor { colors[lane % colors.count] }

    var commit: GraphCommit?
    var isHead = false
    /// Under an expanded commit: just these lanes, straight down.
    var through: [Int]?
    override var isFlipped: Bool { true }

    override func draw(_ r: NSRect) {
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
        func segment(_ l: [Int], from y0: CGFloat, to y1: CGFloat, color: NSColor) {
            guard l.count == 2 else { return }
            let x0 = Self.x(l[0]), x1 = Self.x(l[1]), path = NSBezierPath()
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
        for l in commit.bottom {
            segment(l, from: mid, to: bounds.height, color: Self.color(l.count == 2 ? l[1] : commit.lane))
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
