import AppKit
import Core
import DesignKit
import KelpKit

/// The card a commit shows while the pointer rests on its row, in place of a tooltip. It has the whole subject and
/// body, who made the commit and when, its files, how big the change is, the hash to copy, and buttons to open its
/// changes, check it out, or show the commit's menu. It stays while the pointer is on it.
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
    /// Loads the files the commit changed. The card waits for them with the details, so it doesn't grow once up.
    var files: (@MainActor (String) async -> [FileChange]?)?
    /// What a button or a file in the card asks for. The card goes first, except for the menu, which it holds.
    var onAction: (@MainActor (GraphCommit, CommitCardView.Action) -> Void)?

    init() {
        card.onClose = { [weak self] in self?.shown = nil }
    }

    /// Called when the pointer came onto or left a commit's row. A card already up follows the pointer to the next row
    /// at once.
    func hover(_ on: Bool, commit graphCommit: GraphCommit, pushed: Bool?, over row: NSView) {
        guard on else {
            card.closeSoon()
            return
        }
        guard !(card.isShown && shown == graphCommit.hash) else {
            card.cancel()
            return
        }
        let loading = Task {
            async let details = detailsOf(graphCommit.hash)
            async let changed = files?(graphCommit.hash)
            return await (details, changed)
        }
        card.open { [weak self] in
            let (loaded, changed) = await loading.value
            guard !Task.isCancelled, let self, row.window != nil else { return }
            self.show(graphCommit, details: loaded, files: changed ?? nil, pushed: pushed, over: row)
        }
    }

    func close() { card.close() }

    private func detailsOf(_ hash: String) async -> CommitDetails? {
        if let known = details[hash] { return known }
        let loaded = await load?(hash)
        details[hash] = loaded
        return loaded
    }

    private func show(
        _ commit: GraphCommit, details commitDetails: CommitDetails?, files: [FileChange]?, pushed: Bool?,
        over row: NSView
    ) {
        let email = commitDetails?.email.lowercased() ?? ""
        let view = CommitCardView(
            commit, details: commitDetails, files: files, pushed: pushed, picture: pictures[email])
        view.onInside = { [weak self] inside in if inside { self?.card.cancel() } else { self?.card.closeSoon() } }
        view.onAction = { [weak self] action in
            if case .menu = action {} else { self?.close() }
            self?.onAction?(commit, action)
        }
        let vc = NSViewController()
        vc.view = view
        vc.preferredContentSize = view.fittingSize
        shown = commit.hash
        card.show(vc, relativeTo: row.bounds, of: row, edge: .minX)
        guard !email.isEmpty, pictures[email] == nil else { return }
        Task { [weak self, weak view] in
            guard let img = await self?.picture?(email) else { return }
            self?.pictures[email] = img
            guard self?.shown == commit.hash, let avatar = view?.avatar else { return }
            avatar.crossfade()   // the initial dissolves into the picture
            avatar.image = img
        }
    }
}

/// The card's content: the type and scope, the subject and the body, then who and when, the files, how big, the hash,
/// and the commit's actions.
final class CommitCardView: NSView {
    /// What the card's buttons ask for: the commit's changes, one file's, a check-out, or the menu at the ⋯ button.
    enum Action {
        case open, file(String), checkOut, menu(NSView)
    }
    var onInside: ((Bool) -> Void)?
    var onAction: ((Action) -> Void)?
    /// The most files listed; the rest are "N more", which opens the commit's changes.
    static let fileRows = 5
    static let width: CGFloat = 320
    /// The author's picture, or the author's initial until it comes (or when the forge has none).
    let avatar = NSImageView()

    init(
        _ commit: GraphCommit, details commitDetails: CommitDetails?, files: [FileChange]?, pushed: Bool?,
        picture: NSImage?
    ) {
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
        let title = Self.text(
            subject.text, font: .ui(TextSize.heading, weight: .semibold), color: .labelColor, lines: 4)
        if subject.breaking {   // a breaking change gets a grey "!" before the words, as in the row
            let breakingTitle = NSMutableAttributedString(
                string: "! ",
                attributes: [
                    .font: NSFont.ui(TextSize.heading, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor
                ])
            breakingTitle.append(
                NSAttributedString(
                    string: subject.text,
                    attributes: [
                        .font: NSFont.ui(TextSize.heading, weight: .semibold), .foregroundColor: NSColor.labelColor
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
        if let files, !files.isEmpty { rows.append(fileList(files, lines: commitDetails?.lines ?? [])) }
        rows.append(Self.footer(commit, details: commitDetails))
        rows.append(actions())
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gapWide
        stack.setCustomSpacing(10, after: line)
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)   // a popover's 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate(
            rows.map { $0.widthAnchor.constraint(equalToConstant: Self.width - 2 * Metrics.inset) } + [
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
            let icon = NSImageView(image: .symbol(mark))
            icon.symbolConfiguration = .chrome(Metrics.iconSmall)
            icon.contentTintColor = .secondaryLabelColor
            let kind =
                subject.type.map { [$0, subject.scope].compactMap { $0 }.joined(separator: " · ") }
                ?? String(localized: "Merge commit")
            views += [icon, label(kind, font: .ui(TextSize.caption))]
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

    /// The commit's first files, each with its lines added and removed; a click opens that file's change. The rest are
    /// "N more", which opens all of the commit's changes.
    private func fileList(_ files: [FileChange], lines: [FileLines]) -> NSView {
        let counts = Dictionary(lines.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var views: [NSView] = files.prefix(Self.fileRows).map { file in
            let title = NSMutableAttributedString(
                string: file.path,
                attributes: [.font: NSFont.uiMono(TextSize.caption), .foregroundColor: NSColor.secondaryLabelColor])
            if let count = counts[file.path], count.added + count.removed > 0 {
                title.append(NSAttributedString(string: "  "))
                title.append(GitFolders.changes(added: count.added, removed: count.removed))
            }
            let button = PointerButton(title: "") { [weak self] in self?.onAction?(.file(file.path)) }
            button.attributedTitle = title
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle   // the file's name and its counts are at the ends
            button.padding = Metrics.gapTight
            button.toolTip = file.path
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return button
        }
        if files.count > Self.fileRows {
            views.append(
                PointerButton.link(
                    String(localized: "\(files.count - Self.fileRows) more"), font: .ui(TextSize.caption)
                ) { [weak self] in self?.onAction?(.open) })
        }
        let list = NSStackView(views: views)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        for view in views { view.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor).isActive = true }
        return list
    }

    /// Open Changes, the card's one main action, then Check Out… and the commit's menu under ⋯.
    private func actions() -> NSView {
        let open = ClosureButton(title: String(localized: "Open Changes")) { [weak self] in self?.onAction?(.open) }
        open.bezelStyle = .push
        open.controlSize = .small
        // The card's one main action, in the accent colour (macOS 26's primary tint, and the bezel colour before it).
        if #available(macOS 26, *) {
            open.tintProminence = .primary
        } else {
            open.bezelColor = .controlAccentColor
        }
        let checkOut = TextButton(String(localized: "Check Out…")) { [weak self] in self?.onAction?(.checkOut) }
        weak var more: IconButton?
        let menu = IconButton(.symbol("ellipsis"), tip: String(localized: "More")) { [weak self] in
            if let more { self?.onAction?(.menu(more)) }
        }
        more = menu
        let row = NSStackView(views: [open, checkOut, menu, NSView()])
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
        let author = label(commit.author, font: .ui(TextSize.caption))
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
        // A button named in words carries no symbol: the hash is its name, and it says "Copied" for a moment.
        let hash = String(commit.hash.prefix(7))
        weak var button: NSButton?
        let copy = ClosureButton(title: hash) {
            copyText(commit.hash)
            button?.crossfade()
            button?.title = String(localized: "Copied")
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.linger) {
                button?.crossfade()
                button?.title = hash
            }
        }
        button = copy
        copy.font = .uiMono(TextSize.caption)
        copy.bezelStyle = .push
        copy.controlSize = .small
        copy.toolTip = String(localized: "Copy Commit Hash")
        let row = NSStackView(views: views + [NSView(), copy])
        row.spacing = Metrics.gap
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
        field.preferredMaxLayoutWidth = width - 2 * Metrics.inset
        return field
    }
}
