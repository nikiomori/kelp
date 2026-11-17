// The start view's parts: its boxes, cards, rows and the Run group.
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// A rounded box in the system's grouped style: a soft fill and a hairline.
@MainActor
final class StartBox: NSView {
    private let radius: CGFloat
    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.fillRest.cgColor
    }
}

/// Choices in one grouped box, like a Settings list, with a line between rows. With `columns: 2`, there are two to a
/// row.
@MainActor
final class StartCard: NSView {
    /// The distance from the card's edge to its rows' highlight.
    static let inset: CGFloat = 4

    init(rows: [NSView], columns: Int = 1) {
        super.init(frame: .zero)
        let box = StartBox(radius: Metrics.radiusXL)   // the card
        let lines: [NSView] =
            columns == 1
            ? rows
            : stride(from: 0, to: rows.count, by: columns).map { first in
                let pair = NSStackView(views: (first..<first + columns).map { $0 < rows.count ? rows[$0] : NSView() })
                pair.distribution = .fillEqually
                pair.spacing = Self.inset
                return pair
            }
        var views: [NSView] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                views.append(sep)
            }
            views.append(line)
        }
        let list = NSStackView(views: views)
        list.orientation = .vertical
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        pin(box)
        pin(list)
        for view in views {
            if view is NSBox {
                view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -40).isActive = true
            }   // inset like grouped lists
            else {
                view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -2 * Self.inset).isActive = true
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// What the run chip runs, and its list, under a heading of their own. The group is hidden while the project offers
/// nothing to run, and it follows the files as they're read.
@MainActor
final class RunGroup: NSStackView {
    let head = StartView.heading(String(localized: "Run"))

    init(app: AppModel, workspace wid: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 0, right: 0)
        // Rebuild the rows when what they say changes.
        track(owner: self) {
            (app.extensions.all.runs?.choices(wid) ?? []).map { [$0.title, $0.help ?? "", $0.key?.description ?? ""] }
        } changed: { [weak self] _ in
            self?.show(app.extensions.all.runs?.choices(wid) ?? [])
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func show(_ run: [NewTabChoices.Action]) {
        isHidden = run.isEmpty
        let card = StartCard(rows: run.map(StartRow.init), columns: 2)
        setViews([head, card], in: .top)
        head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: StartView.headInset).isActive = true
        card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

/// One action row: a symbol, a title, a detail and its shortcut on the right; it highlights on hover.
@MainActor
final class StartRow: PointerControl {

    /// The distance from the edge of the row's highlight to its icon.
    static let inset: CGFloat = 10

    convenience init(_ a: NewTabChoices.Action) {
        self.init(image: .symbol(a.symbol), title: a.title, shortcut: a.key.map(KeyBindings.display), action: a.run)
        toolTip = a.help
    }

    init(image: NSImage?, title: String, detail: String? = nil, shortcut: String?, action: @escaping () -> Void) {
        super.init(frame: .zero)
        onClick = action
        layer?.cornerRadius = Metrics.radiusMD
        let icon = NSImageView(image: image ?? NSImage())
        icon.symbolConfiguration = .chrome(Metrics.iconLarge)
        icon.contentTintColor = .secondaryLabelColor   // symbols only; real icons keep their colors
        let label = NSTextField(labelWithString: title)
        label.font = .ui(TextSize.body)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let more = NSTextField(labelWithString: detail ?? "")
        more.textColor = .secondaryLabelColor
        more.font = .ui(TextSize.row)
        more.lineBreakMode = .byTruncatingTail
        more.setContentCompressionResistancePriority(.init(240), for: .horizontal)   // the name wins
        let key = NSTextField(labelWithString: shortcut ?? "")
        key.textColor = .secondaryLabelColor
        key.font = .ui(TextSize.row)
        let row = NSStackView(views: [icon, label, NSView(), more, key])
        row.spacing = Metrics.gapWide
        row.detachesHiddenViews = true
        more.isHidden = detail == nil
        key.isHidden = shortcut == nil
        row.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: Self.inset)
        pin(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.rowCard)),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconButton)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

}

/// The project's group templates (`LayoutTemplates`), shown first on an empty screen: the ones saved here, then the
/// .kelp.yaml's templates once that file is read (and trusted). A click arranges this screen as the template says; the
/// list is hidden while there are none. A saved template's menu deletes it; a template from the file is changed in the
/// file.
@MainActor
final class TemplateGroup: NSStackView {
    let head = StartView.heading(String(localized: "Templates"))
    private let store: LayoutTemplates, workspace: Worktree

    init(app: AppModel, workspace worktree: Worktree) {
        store = LayoutTemplates(app: app)
        workspace = worktree
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        show(file: [])
        Task { [weak self] in
            let file = await LayoutTemplates(app: app).fromFile(worktree)
            if !file.isEmpty { self?.show(file: file) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func show(file: [LayoutTemplate]) {
        let store = store, w = workspace, saved = store.all(w.repoId)
        isHidden = saved.isEmpty && file.isEmpty
        let rows = (saved.map { ($0, true) } + file.map { ($0, false) }).map { t, mine in
            let row = StartRow(
                image: .symbol("rectangle.split.2x1"), title: t.name, detail: store.summary(t), shortcut: nil
            ) {
                Task { await store.use(t, in: w.id) }
            }
            guard mine else { return row }
            row.menu = NSMenu()
            row.menu?.add(String(localized: "Delete Template")) { [weak self] in
                store.delete(t.name, in: w.repoId)
                self?.show(file: file)
            }
            return row
        }
        let card = StartCard(rows: rows)
        setViews([head, card], in: .top)
        head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: StartView.headInset).isActive = true
        card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}
