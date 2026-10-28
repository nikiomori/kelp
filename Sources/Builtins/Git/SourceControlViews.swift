import AppKit
import Core
import DesignKit
import WorkbenchKit
import KelpKit

struct RowAction {
    let symbol: String, title: String, run: @MainActor () -> Void
    /// `title` in English; it shows translated (tooltip, accessibility, context menu).
    init(_ symbol: String, _ title: String, _ run: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.title = loc(title)
        self.run = run
    }
}

@MainActor
private func actionButtons(_ actions: [RowAction]) -> NSStackView {
    let s = NSStackView(views: actions.map { a in
        let b = ClosureButton(title: "") { a.run() }
        b.image = .symbol(a.symbol, a.title)
        b.isBordered = false
        b.toolTip = a.title
        b.symbolConfiguration = .init(pointSize: 11, weight: .medium); b.contentTintColor = .secondaryLabelColor
        b.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    })
    s.spacing = 2; s.isHidden = true
    return s
}

@MainActor
private func pinRow(_ cell: NSView, _ views: [NSView], leading: CGFloat, trailing: CGFloat = 10) {
    let row = NSStackView(views: views)
    row.spacing = Metrics.gap
    row.alignment = .centerY
    row.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(row)
    NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
                                 row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -trailing),
                                 row.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
}

final class SectionCell: NSTableCellView, Hoverable {
    private let chevron = NSImageView()
    private let actions: NSStackView
    var expanded = true { didSet { showChevron() } }
    private func showChevron() { chevron.image = .symbol(expanded ? "chevron.down" : "chevron.right") }
    init(title: String, count: Int?, expanded: Bool, actions a: [RowAction], detail: NSAttributedString? = nil) {
        actions = actionButtons(a)
        super.init(frame: .zero)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold); chevron.contentTintColor = .secondaryLabelColor
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let t = NSTextField(labelWithString: title)
        t.font = .ui(11, weight: .semibold)
        t.textColor = .secondaryLabelColor
        let c = NSTextField(labelWithString: count.map(String.init) ?? ""); c.font = .uiDigits(11, weight: .medium)
        c.textColor = .secondaryLabelColor
        let d = NSTextField(labelWithAttributedString: detail ?? NSAttributedString())
        d.isHidden = detail == nil
        pinRow(self, [chevron, t, NSView(), actions, d, c], leading: 10)
        self.expanded = expanded; showChevron()   // didSet doesn't run in init
    }
    required init?(coder: NSCoder) { fatalError() }
    func setHover(_ on: Bool) { actions.isHidden = !on }
}

/// The Graph pane's header: a click folds the pane, a drag sizes it (VS Code's view header and sash in one).
final class GraphBar: NSView {
    static let height = TextSize.of(26) + 1
    var onToggle: (() -> Void)?, onResize: ((CGFloat) -> Void)?, onRefresh: (() -> Void)?
    var expanded = true { didSet { cell?.expanded = expanded; window?.invalidateCursorRects(for: self) } }
    private var cell: SectionCell?

    init() {
        super.init(frame: .zero)
        let c = SectionCell(title: loc(SourceControlController.Section.graph.rawValue), count: nil, expanded: true,
                            actions: [RowAction("arrow.clockwise", "Refresh") { [weak self] in self?.onRefresh?() }])
        let sep = NSBox(); sep.boxType = .separator
        for v in [sep, c] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: topAnchor), sep.heightAnchor.constraint(equalToConstant: 1),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            c.topAnchor.constraint(equalTo: sep.bottomAnchor), c.bottomAnchor.constraint(equalTo: bottomAnchor),
            c.leadingAnchor.constraint(equalTo: leadingAnchor), c.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        cell = c; clipsToBounds = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(loc("Graph"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { cell?.setHover(true) }
    override func mouseExited(with e: NSEvent) { cell?.setHover(false) }
    override func resetCursorRects() {
        if expanded { addCursorRect(NSRect(x: 0, y: bounds.height - 4, width: bounds.width, height: 4), cursor: .resizeUpDown) }
    }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
    override func accessibilityValue() -> Any? { expanded }

    private var start: CGFloat = 0, last: CGFloat = 0, dragged = false
    override func mouseDown(with e: NSEvent) {
        start = e.locationInWindow.y
        last = start
        dragged = false
    }
    override func mouseDragged(with e: NSEvent) {
        let y = e.locationInWindow.y
        dragged = dragged || (expanded && abs(y - start) > 3)
        if dragged { onResize?(y - last); last = y }
    }
    override func mouseUp(with e: NSEvent) { if !dragged { onToggle?() } }
}

final class FileCell: NSTableCellView, Hoverable {
    private let actions: NSStackView
    init(_ f: FileChange, icon image: NSImage, letter: (String, NSColor), indent: CGFloat, actions a: [RowAction]) {
        actions = actionButtons(a)
        super.init(frame: .zero)
        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true; icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: (f.path as NSString).lastPathComponent); name.font = .ui(12)
        name.lineBreakMode = .byTruncatingTail
        if letter.0 == "D" {
            name.attributedStringValue = NSAttributedString(string: name.stringValue, attributes: [.strikethroughStyle: 1, .font: NSFont.ui(12)])
        }
        let dir = NSTextField(labelWithString: (f.path as NSString).deletingLastPathComponent); dir.font = .ui(11)
        dir.textColor = .secondaryLabelColor; dir.lineBreakMode = .byTruncatingHead
        dir.setContentCompressionResistancePriority(.init(200), for: .horizontal); name.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        let l = NSTextField(labelWithString: letter.0)
        l.font = .uiMono(11, weight: .semibold)
        l.textColor = letter.1
        l.alignment = .center; l.widthAnchor.constraint(equalToConstant: 12).isActive = true
        pinRow(self, [icon, name, dir, NSView(), actions, l], leading: indent + 10)
        toolTip = f.path
    }
    required init?(coder: NSCoder) { fatalError() }
    func setHover(_ on: Bool) { actions.isHidden = !on }
}

final class NoteCell: NSTableCellView {
    init(_ text: String) {
        super.init(frame: .zero)
        let t = NSTextField(labelWithString: text)
        t.font = .ui(12)
        t.textColor = .secondaryLabelColor
        pinRow(self, [t], leading: 26)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class CommitCell: NSTableCellView, Hoverable {
    private let subject: NSTextField, up = NSImageView()
    /// The pointer came onto or left the row: the commit's card follows it.
    var onHover: ((Bool) -> Void)?
    func setHover(_ on: Bool) { onHover?(on) }

    /// The commit's line; its branch or tag leads it, right after its dot.
    static var lineHeight: CGFloat { TextSize.of(Metrics.row) }

    /// `pushed` is nil without a remote; a commit not pushed yet has an arrow before its time.
    /// A commit that just reached the remote (`landsAfter`) starts as it was and lands after that many seconds.
    init(_ c: GraphCommit, graphWidth: CGFloat, isHead: Bool, pushed: Bool?, landsAfter delay: Double? = nil) {
        let s = CommitSubject(c.subject)
        subject = NSTextField(labelWithString: s.text)
        super.init(frame: .zero)
        let unpushed = pushed == false
        let g = GraphView()
        g.commit = c
        g.isHead = isHead
        g.translatesAutoresizingMaskIntoConstraints = false; addSubview(g)
        subject.font = .ui(12, weight: isHead ? .semibold : .regular)
        subject.textColor = .labelColor
        subject.lineBreakMode = .byTruncatingTail; subject.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        // A breaking change ("feat!:"): a red "!" before the words.
        let bang = s.breaking ? NSTextField(labelWithString: "!") : nil
        bang?.font = .ui(12, weight: .bold)
        bang?.textColor = .textRed
        bang?.setAccessibilityLabel(String(localized: "Breaking change"))
        let mark = Self.mark(s, merge: c.parents.count > 1).map { m in
            let v = NSImageView(image: .symbol(m.symbol, s.type ?? String(localized: "Merge commit")))
            // One colour in the list, so the subjects lead; the card under the pointer shows the type's own.
            v.symbolConfiguration = .init(pointSize: 10, weight: .medium); v.contentTintColor = .secondaryLabelColor
            v.widthAnchor.constraint(equalToConstant: 13).isActive = true
            return v
        }
        let scope = NSTextField(labelWithString: s.scope ?? "")
        scope.font = .ui(11)
        scope.textColor = .secondaryLabelColor
        scope.lineBreakMode = .byTruncatingTail; scope.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        scope.widthAnchor.constraint(lessThanOrEqualToConstant: TextSize.of(80)).isActive = true
        let date = NSTextField(labelWithString: Self.relative(c.date))
        date.font = .uiDigits(11)
        date.textColor = .secondaryLabelColor
        // Not on the remote yet: an arrow before the time, as in GitHub Desktop.
        let notPushed = String(localized: "Not pushed yet")
        up.image = .symbol("arrow.up", notPushed); up.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        up.contentTintColor = .secondaryLabelColor
        up.toolTip = notPushed
        up.isHidden = !unpushed && delay == nil
        if let delay { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + delay) { [weak self] in self?.land() } }
        // A row with a branch or tag leaves out the scope: the badge says where the commit is, the words keep their room.
        let badges = Self.badges(c.refs)
        scope.isHidden = !badges.isEmpty
        let row = NSStackView(views: badges + [mark, bang, subject].compactMap { $0 } + [NSView(), scope, up, date])
        row.spacing = 5
        row.alignment = .centerY
        if let bang { row.setCustomSpacing(2, after: bang) }
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            g.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), g.topAnchor.constraint(equalTo: topAnchor),
            g.bottomAnchor.constraint(equalTo: bottomAnchor), g.widthAnchor.constraint(equalToConstant: graphWidth),
            row.leadingAnchor.constraint(equalTo: g.trailingAnchor, constant: 2), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor), row.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        ])
        // The card (CommitCard) shows all this to the pointer; VoiceOver reads it here.
        let when = Date(timeIntervalSince1970: c.date).formatted(date: .abbreviated, time: .shortened)
        setAccessibilityHelp("\(c.subject)\n\n\(c.author) · \(when)\n\(c.hash.prefix(10))" + (c.refs.isEmpty ? "" : "\n" + c.refs.joined(separator: ", "))
            + (unpushed ? "\n" + notPushed : ""))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// While the push runs, the arrows of the commits on their way pulse.
    func pulse(_ on: Bool) {
        guard !up.isHidden else { return }
        if on { up.addSymbolEffect(.pulse, options: .repeating) } else { up.removeAllSymbolEffects() }
    }

    /// Just reached the remote: the arrow hops up and fades.
    private func land() {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !still { up.addSymbolEffect(.bounce.up) }
        up.wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + (still ? 0 : 0.15)
        fade.duration = 0.3
        fade.fillMode = .backwards
        up.layer?.add(fade, forKey: "land"); up.alphaValue = 0
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
            let b = Badge(text: $0.0, color: $0.1, strong: $0.2)
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 72).isActive = true   // a long name ends in "…"
            return b
        }
        if out.count > 1 {
            let more = Badge(text: "+\(out.count - 1)", color: .secondaryLabelColor, strong: false)
            more.toolTip = out.dropFirst().map(\.0).joined(separator: "\n")
            views.append(more)
        }
        return views
    }

    /// Local branches and tags (HEAD's branch first); a remote ref shows only when no local branch of that name is here.
    static func labels(_ refs: [String]) -> [(String, NSColor, Bool)] {
        var out: [(String, NSColor, Bool)] = []
        let locals = Set(refs.compactMap { r -> String? in
            if r.hasPrefix("HEAD -> ") { return String(r.dropFirst(8)) }
            return r.hasPrefix("tag: ") || r.contains("/") || r == "HEAD" ? nil : r
        })
        for r in refs where !r.hasSuffix("/HEAD") {   // origin/HEAD only repeats origin/main
            if r.hasPrefix("HEAD -> ") { out.insert((String(r.dropFirst(8)), .controlAccentColor, true), at: 0) }
            else if r == "HEAD" { out.insert(("HEAD", .controlAccentColor, true), at: 0) }
            else if r.hasPrefix("tag: ") { out.append((String(r.dropFirst(5)), .systemOrange, false)) }
            else if r.contains("/") { if !locals.contains(String(r.drop { $0 != "/" }.dropFirst())) { out.append((r, .secondaryLabelColor, false)) } }
            else { out.append((r, .controlAccentColor, false)) }
        }
        return out
    }

    static func relative(_ t: Double) -> String {
        let s = Date().timeIntervalSince1970 - t
        switch s {
        case ..<(86400 * 7): return shortAgo(Date(timeIntervalSince1970: t))   // "now", "4m", "2h", "3d" in the user's language
        default:
            let d = Date(timeIntervalSince1970: t)
            let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
            return sameYear ? d.formatted(.dateTime.month(.abbreviated).day()) : d.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

/// A small rounded label for a branch or tag.
final class Badge: NSView {
    private let text: NSAttributedString
    private let color: NSColor
    init(text: String, color: NSColor, strong: Bool) {
        self.color = color
        self.text = NSAttributedString(string: text, attributes: [.font: NSFont.ui(10, weight: strong ? .semibold : .medium),
                                                                   .foregroundColor: color])
        super.init(frame: .zero)
        setContentCompressionResistancePriority(.init(300), for: .horizontal)
        toolTip = text
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: min(ceil(text.size().width) + 10, 110), height: 16) }
    override func draw(_ r: NSRect) {
        color.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let w = bounds.width - 10
        text.draw(with: NSRect(x: 5, y: (bounds.height - text.size().height) / 2, width: w, height: text.size().height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// One row of the history graph: lines from the row above to the dot, from the dot to the row below.
final class GraphView: NSView {
    static let maxLanes = 6
    static let step: CGFloat = 11, inset: CGFloat = 7
    static let colors: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemTeal, .systemPink, .systemGreen, .systemIndigo, .systemBrown]
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
            for l in through {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: Self.x(l), y: 0))
                p.line(to: NSPoint(x: Self.x(l), y: bounds.height))
                p.lineWidth = 1.5
                Self.color(l).setStroke()
                p.stroke()
            }
            return
        }
        guard let c = commit else { return }
        let mid = bounds.height / 2
        func segment(_ l: [Int], from y0: CGFloat, to y1: CGFloat, color: NSColor) {
            guard l.count == 2 else { return }
            let x0 = Self.x(l[0]), x1 = Self.x(l[1]), p = NSBezierPath()
            p.move(to: NSPoint(x: x0, y: y0))
            if x0 == x1 { p.line(to: NSPoint(x: x1, y: y1)) }
            else { p.curve(to: NSPoint(x: x1, y: y1), controlPoint1: NSPoint(x: x0, y: (y0 + y1) / 2), controlPoint2: NSPoint(x: x1, y: (y0 + y1) / 2)) }
            p.lineWidth = 1.5
            color.setStroke()
            p.stroke()
        }
        for l in c.top { segment(l, from: 0, to: mid, color: Self.color(l[0])) }
        for l in c.bottom { segment(l, from: mid, to: bounds.height, color: Self.color(l.count == 2 ? l[1] : c.lane)) }
        let x = Self.x(c.lane), col = Self.color(c.lane)
        if isHead {
            let ring = NSBezierPath(ovalIn: NSRect(x: x - 4.5, y: mid - 4.5, width: 9, height: 9))
            NSColor.windowBackgroundColor.setFill(); ring.fill()
            ring.lineWidth = 2
            col.setStroke()
            ring.stroke()
        } else {
            col.setFill(); NSBezierPath(ovalIn: NSRect(x: x - 3.5, y: mid - 3.5, width: 7, height: 7)).fill()
        }
    }
}

/// The commit message: ⌘↩ commits, like VS Code.
final class CommitTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onChange: (() -> Void)?
    private func isCommitKey(_ e: NSEvent) -> Bool { (e.keyCode == 36 || e.keyCode == 76) && e.modifierFlags.contains(.command) }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, isCommitKey(e) { onCommit?(); return true }
        return super.performKeyEquivalent(with: e)
    }
    override func keyDown(with e: NSEvent) { if isCommitKey(e) { onCommit?() } else { super.keyDown(with: e) } }
    override func didChangeText() { super.didChangeText(); onChange?() }
}

/// The message field's rounded border; AppKit calls `updateLayer` again on every light / dark change.
final class FieldBox: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6; layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor; layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}
