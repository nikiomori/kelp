import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The card a commit shows while the pointer rests on its row, in place of a tooltip: the whole subject and body, who
/// and when, how big the change is, and the hash to copy. It stays while the pointer is on it.
@MainActor
final class CommitCard {
    private let popover = NSPopover()
    private var shown: String?
    private var opening: Task<Void, Never>?, closing: Task<Void, Never>?
    private var details: [String: CommitDetails] = [:]
    private var pictures: [String: NSImage] = [:]
    /// The daemon's details of a commit; without them the card shows what the graph knows.
    var load: (@MainActor (String) async -> CommitDetails?)?
    /// The author's picture from the project's forge, by email; without one the card keeps the initial.
    var picture: (@MainActor (String) async -> NSImage?)?

    init() {   // as the sidebar's: it goes when the pointer leaves, and moves from row to row without popping
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    /// The pointer came onto or left a commit's row. A card already up follows the pointer to the next row at once.
    func hover(_ on: Bool, commit c: GraphCommit, pushed: Bool?, over row: NSView) {
        opening?.cancel()
        guard on else {
            closeSoon()
            return
        }
        closing?.cancel()
        guard !(popover.isShown && shown == c.hash) else { return }
        let wait: Duration = .seconds(popover.isShown ? Motion.hoverOpenWarm : Motion.hoverOpen)
        let loading = Task { await detailsOf(c.hash) }
        opening = Task { [weak self] in
            try? await Task.sleep(for: wait)
            let loaded = await loading.value
            guard !Task.isCancelled, let self, row.window != nil else { return }
            self.show(c, details: loaded, pushed: pushed, over: row)
        }
    }

    func close() {
        opening?.cancel()
        closing?.cancel()
        shown = nil
        if popover.isShown { popover.performClose(nil) }
    }

    private func closeSoon() {
        closing?.cancel()
        closing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Motion.hoverClose))
            if !Task.isCancelled { self?.close() }
        }
    }

    private func detailsOf(_ hash: String) async -> CommitDetails? {
        if let known = details[hash] { return known }
        let loaded = await load?(hash)
        details[hash] = loaded
        return loaded
    }

    private func show(_ c: GraphCommit, details d: CommitDetails?, pushed: Bool?, over row: NSView) {
        let email = d?.email.lowercased() ?? ""
        let card = CommitCardView(c, details: d, pushed: pushed, picture: pictures[email])
        card.onInside = { [weak self] inside in if inside { self?.closing?.cancel() } else { self?.closeSoon() } }
        let vc = NSViewController()
        vc.view = card
        popover.contentViewController = vc
        popover.contentSize = card.fittingSize
        shown = c.hash
        popover.show(relativeTo: row.bounds, of: row, preferredEdge: .minX)   // shown already: it moves to this row
        guard !email.isEmpty, pictures[email] == nil else { return }
        Task { [weak self, weak card] in
            guard let img = await self?.picture?(email) else { return }
            self?.pictures[email] = img
            if self?.shown == c.hash { card?.avatar.image = img }
        }
    }
}

/// The card's content: the type and scope, the subject, the body, then who, when, how big and the hash.
final class CommitCardView: NSView {
    var onInside: ((Bool) -> Void)?
    static let width: CGFloat = 320
    /// The author's picture, or their initial until it comes (or when the forge has none).
    let avatar = NSImageView()

    init(_ c: GraphCommit, details d: CommitDetails?, pushed: Bool?, picture: NSImage?) {
        super.init(frame: .zero)
        let size = TextSize.of(18)
        avatar.image = picture ?? Self.initial(c.author, size: size)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = size / 2
        avatar.layer?.masksToBounds = true
        avatar.setAccessibilityElement(false)   // the name follows it
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: size), avatar.heightAnchor.constraint(equalToConstant: size)
        ])
        let subject = CommitSubject(c.subject)
        var rows: [NSView] = []
        if let head = Self.header(subject, merge: c.parents.count > 1, unpushed: pushed == false) { rows.append(head) }
        let title = Self.text(subject.text, font: .ui(TextSize.body, weight: .semibold), color: .labelColor, lines: 4)
        if subject.breaking {   // a breaking change: a red "!" before the words, as in the row
            let breakingTitle = NSMutableAttributedString(
                string: "! ",
                attributes: [.font: NSFont.ui(TextSize.body, weight: .semibold), .foregroundColor: NSColor.textRed])
            breakingTitle.append(
                NSAttributedString(
                    string: subject.text,
                    attributes: [
                        .font: NSFont.ui(TextSize.body, weight: .semibold), .foregroundColor: NSColor.labelColor
                    ]))
            title.attributedStringValue = breakingTitle
            title.setAccessibilityLabel(String(localized: "Breaking change") + ": " + subject.text)
        }
        rows.append(title)
        if let body = d?.body, !body.isEmpty {
            rows.append(
                Self.text(CommitSubject.reflow(body), font: .ui(TextSize.row), color: .secondaryLabelColor, lines: 12))
        }
        let line = NSBox()
        line.boxType = .separator
        rows.append(line)
        let refs = CommitCell.labels(c.refs)
        if !refs.isEmpty {
            let badges = NSStackView(
                views: refs.prefix(4).map { Badge(text: $0.0, color: $0.1, strong: $0.2) } + [NSView()])
            badges.spacing = 4
            rows.append(badges)
        }
        rows.append(Self.meta(c, avatar: avatar))
        rows.append(Self.footer(c, details: d))
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(10, after: line)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate(
            rows.map { $0.widthAnchor.constraint(equalToConstant: Self.width - 28) } + [
                stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                widthAnchor.constraint(equalToConstant: Self.width)
            ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // The card is never key (it would take focus from the editor): the pointer is tracked while the app is in the back too.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onInside?(true) }
    override func mouseExited(with e: NSEvent) { onInside?(false) }

    /// The type's mark, "fix · daemon" and "↑ Not pushed yet"; nothing for a plain subject that's on the remote.
    private static func header(_ subject: CommitSubject, merge: Bool, unpushed: Bool) -> NSView? {
        var views: [NSView] = []
        if let mark = CommitCell.mark(subject, merge: merge) {
            let icon = NSImageView(image: .symbol(mark.symbol))
            icon.symbolConfiguration = .chrome(Metrics.iconSmall)
            icon.contentTintColor = mark.color
            let kind =
                subject.type.map { [$0, subject.scope].compactMap { $0 }.joined(separator: " · ") }
                ?? String(localized: "Merge commit")
            views += [icon, label(kind, font: .ui(TextSize.caption, weight: .medium))]
        }
        for v in views { v.setContentCompressionResistancePriority(.init(760), for: .horizontal) }   // "Not pushed yet" gives way
        if unpushed {
            let up = NSImageView(image: .symbol("arrow.up"))
            up.symbolConfiguration = .chrome(Metrics.iconTiny)
            up.contentTintColor = .secondaryLabelColor
            views += [NSView(), up, label(String(localized: "Not pushed yet"), font: .ui(TextSize.caption))]
        }
        guard !views.isEmpty else { return nil }
        let row = NSStackView(views: views)
        row.spacing = 5
        return row
    }

    /// A letter in a circle of a colour the name picks (the graph's lane colours).
    static func initial(_ name: String, size: CGFloat) -> NSImage {
        let color = GraphView.color(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        let letter = NSAttributedString(
            string: name.first.map { String($0).uppercased() } ?? "?",
            attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.5, weight: .semibold), .foregroundColor: NSColor.white
            ])
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let letterSize = letter.size()
            letter.draw(at: NSPoint(x: (rect.width - letterSize.width) / 2, y: (rect.height - letterSize.height) / 2))
            return true
        }
    }

    /// The author's picture, "Nikolay · 3h ago · Oct 22, 8:17 PM".
    private static func meta(_ c: GraphCommit, avatar: NSView) -> NSView {
        let date = Date(timeIntervalSince1970: c.date), age = Date().timeIntervalSince(date)
        let ago = age < 60 ? String(localized: "now") : String(localized: "\(shortSpan(age)) ago")
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let when = date.formatted(
            sameYear
                ? .dateTime.month(.abbreviated).day().hour().minute()
                : .dateTime.month(.abbreviated).day().year().hour().minute())
        let author = label(c.author, font: .ui(TextSize.caption, weight: .medium))
        author.textColor = .secondaryLabelColor
        author.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let row = NSStackView(views: [
            avatar, author, label("· \(ago) · \(when)", font: .ui(TextSize.caption)), NSView()
        ])
        row.spacing = 4
        row.setCustomSpacing(6, after: avatar)
        return row
    }

    /// "4 files +31 −11" and the short hash, which copies the whole one.
    private static func footer(_ c: GraphCommit, details: CommitDetails?) -> NSView {
        var views: [NSView] = []
        if let details, details.files > 0 {
            views.append(label(String(localized: "\(details.files) files"), font: .uiDigits(TextSize.caption)))
            if details.added + details.removed > 0 {
                views.append(
                    NSTextField(
                        labelWithAttributedString: GitFolders.changes(added: details.added, removed: details.removed)))
            }
        }
        let copyTitle = String(localized: "Copy Commit Hash")
        weak var button: NSButton?
        let copy = ClosureButton(title: String(c.hash.prefix(7))) {
            copyText(c.hash)
            button?.crossfade()
            button?.image = .symbol("checkmark", String(localized: "Copied"))
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.linger) {
                button?.crossfade()
                button?.image = .symbol("doc.on.doc", copyTitle)
            }
        }
        button = copy
        copy.font = .monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular)
        copy.image = .symbol("doc.on.doc", copyTitle)
        copy.imagePosition = .imageTrailing
        copy.bezelStyle = .push
        copy.controlSize = .small
        copy.toolTip = copyTitle
        let row = NSStackView(views: views + [NSView(), copy])
        row.spacing = 6
        return row
    }

    private static func label(_ string: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private static func text(_ string: String, font: NSFont, color: NSColor, lines: Int) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.maximumNumberOfLines = lines
        field.cell?.truncatesLastVisibleLine = true
        field.preferredMaxLayoutWidth = width - 28
        return field
    }
}
