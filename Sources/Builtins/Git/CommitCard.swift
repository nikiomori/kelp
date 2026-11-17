import AppKit
import Core
import DesignKit
import KelpKit

/// The card a commit shows while the pointer rests on its row, in place of a tooltip. It has the whole subject and
/// body, who made the commit and when, how big the change is, and the hash to copy. It stays while the pointer is on
/// it.
@MainActor
final class CommitCard {
    private let card = HoverPopover()
    private var shown: String?
    private var details: [String: CommitDetails] = [:]
    private var pictures: [String: NSImage] = [:]
    /// Loads the daemon's details of a commit; without them the card shows what the graph knows.
    var load: (@MainActor (String) async -> CommitDetails?)?
    /// Loads the author's picture from the project's forge, by email; without one the card keeps the initial.
    var picture: (@MainActor (String) async -> NSImage?)?

    init() {
        card.onClose = { [weak self] in self?.shown = nil }
    }

    /// Called when the pointer came onto or left a commit's row. A card already up follows the pointer to the next row
    /// at once.
    func hover(_ on: Bool, commit c: GraphCommit, pushed: Bool?, over row: NSView) {
        guard on else {
            card.closeSoon()
            return
        }
        guard !(card.isShown && shown == c.hash) else {
            card.cancel()
            return
        }
        let loading = Task { await detailsOf(c.hash) }
        card.open { [weak self] in
            let loaded = await loading.value
            guard !Task.isCancelled, let self, row.window != nil else { return }
            self.show(c, details: loaded, pushed: pushed, over: row)
        }
    }

    func close() { card.close() }

    private func detailsOf(_ hash: String) async -> CommitDetails? {
        if let known = details[hash] { return known }
        let loaded = await load?(hash)
        details[hash] = loaded
        return loaded
    }

    private func show(_ commit: GraphCommit, details commitDetails: CommitDetails?, pushed: Bool?, over row: NSView) {
        let email = commitDetails?.email.lowercased() ?? ""
        let view = CommitCardView(commit, details: commitDetails, pushed: pushed, picture: pictures[email])
        view.onInside = { [weak self] inside in if inside { self?.card.cancel() } else { self?.card.closeSoon() } }
        let vc = NSViewController()
        vc.view = view
        vc.preferredContentSize = view.fittingSize
        shown = commit.hash
        card.show(vc, relativeTo: row.bounds, of: row, edge: .minX)
        guard !email.isEmpty, pictures[email] == nil else { return }
        Task { [weak self, weak view] in
            guard let img = await self?.picture?(email) else { return }
            self?.pictures[email] = img
            if self?.shown == commit.hash { view?.avatar.image = img }
        }
    }
}

/// The card's content: the type and scope, the subject and the body, then who, when, how big, and the hash.
final class CommitCardView: NSView {
    var onInside: ((Bool) -> Void)?
    static let width: CGFloat = 320
    /// The author's picture, or the author's initial until it comes (or when the forge has none).
    let avatar = NSImageView()

    init(_ commit: GraphCommit, details commitDetails: CommitDetails?, pushed: Bool?, picture: NSImage?) {
        super.init(frame: .zero)
        let size = TextSize.of(18)
        avatar.image = picture ?? Self.initial(commit.author, size: size)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = size / 2
        avatar.layer?.masksToBounds = true
        avatar.setAccessibilityElement(false)   // the author's name follows it
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: size), avatar.heightAnchor.constraint(equalToConstant: size)
        ])
        let subject = CommitSubject(commit.subject)
        var rows: [NSView] = []
        if let head = Self.header(subject, merge: commit.parents.count > 1, unpushed: pushed == false) {
            rows.append(head)
        }
        let title = Self.text(subject.text, font: .ui(TextSize.body, weight: .semibold), color: .labelColor, lines: 4)
        if subject.breaking {   // a breaking change gets a red "!" before the words, as in the row
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
        if let body = commitDetails?.body, !body.isEmpty {
            rows.append(
                Self.text(CommitSubject.reflow(body), font: .ui(TextSize.row), color: .secondaryLabelColor, lines: 12))
        }
        let line = NSBox()
        line.boxType = .separator
        rows.append(line)
        let refs = CommitCell.labels(commit.refs)
        if !refs.isEmpty {
            let badges = NSStackView(
                views: refs.prefix(4).map { Badge(text: $0.0, color: $0.1, strong: $0.2) } + [NSView()])
            badges.spacing = 4
            rows.append(badges)
        }
        rows.append(Self.meta(commit, avatar: avatar))
        rows.append(Self.footer(commit, details: commitDetails))
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

    // The card is never key, because it would take focus from the editor. So the pointer is tracked while the app is
    // in the back too.
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area = retracked(area, .activeAlways)
    }
    override func mouseEntered(with event: NSEvent) { onInside?(true) }
    override func mouseExited(with event: NSEvent) { onInside?(false) }

    /// The header: the type's mark, "fix · daemon" and "↑ Not pushed yet". Nil for a plain subject that's on the
    /// remote.
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
        // The type and scope resist squeezing, so "Not pushed yet" gives way first.
        for v in views { v.setContentCompressionResistancePriority(.init(760), for: .horizontal) }
        if unpushed {
            let up = NSImageView(image: .symbol("arrow.up"))
            up.symbolConfiguration = .chrome(Metrics.iconTiny)
            up.contentTintColor = .secondaryLabelColor
            views += [NSView(), up, label(String(localized: "Not pushed yet"), font: .ui(TextSize.caption))]
        }
        guard !views.isEmpty else { return nil }
        let row = NSStackView(views: views)
        row.spacing = Metrics.gap
        return row
    }

    /// A letter in a circle, in a colour the name picks from the graph's lane colours.
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

    /// The author's picture and "Nikolay · 3h ago · Oct 22, 8:17 PM".
    private static func meta(_ commit: GraphCommit, avatar: NSView) -> NSView {
        let date = Date(timeIntervalSince1970: commit.date), age = Date().timeIntervalSince(date)
        let ago = age < 60 ? String(localized: "now") : String(localized: "\(shortSpan(age)) ago")
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let when = date.formatted(
            sameYear
                ? .dateTime.month(.abbreviated).day().hour().minute()
                : .dateTime.month(.abbreviated).day().year().hour().minute())
        let author = label(commit.author, font: .ui(TextSize.caption, weight: .medium))
        author.textColor = .secondaryLabelColor
        author.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let row = NSStackView(views: [
            avatar, author, label("· \(ago) · \(when)", font: .ui(TextSize.caption)), NSView()
        ])
        row.spacing = 4
        row.setCustomSpacing(6, after: avatar)
        return row
    }

    /// "4 files +31 −11" and the short hash, which copies the whole hash.
    private static func footer(_ commit: GraphCommit, details: CommitDetails?) -> NSView {
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
        let copy = ClosureButton(title: String(commit.hash.prefix(7))) {
            copyText(commit.hash)
            button?.crossfade()
            button?.image = .symbol("checkmark", String(localized: "Copied"))
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.linger) {
                button?.crossfade()
                button?.image = .symbol("doc.on.doc", copyTitle)
            }
        }
        button = copy
        copy.font = .uiMono(TextSize.caption)
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
        NSTextField.label(string, font: font, color: .secondaryLabelColor)
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
