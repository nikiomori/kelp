// The start view's parts: its boxes, cards, rows and the Run group.
import Agents
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

/// Choices in one grouped box, like a Settings list, a line between rows; in `columns: 2`, two to a row.
@MainActor
final class StartCard: NSView {
    /// The card's edge to its rows' highlight.
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

/// What the run chip runs and its list, under a heading of their own; gone while the project offers nothing to run.
/// Follows the files as they're read.
@MainActor
final class RunGroup: NSStackView {
    let head = StartView.heading(String(localized: "Run"))

    init(app: AppModel, workspace wid: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 0, right: 0)
        // The rows again when what they say changes.
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

/// One action: symbol, title, a detail and its shortcut on the right; highlights on hover.
@MainActor
final class StartRow: PointerControl {
    private let run: () -> Void

    /// The edge of the row's highlight to its icon.
    static let inset: CGFloat = 10

    convenience init(_ a: NewTabChoices.Action) {
        self.init(image: .symbol(a.symbol), title: a.title, shortcut: a.key.map(KeyBindings.display), action: a.run)
        toolTip = a.help
    }

    init(image: NSImage?, title: String, detail: String? = nil, shortcut: String?, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
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
        row.spacing = 10
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

    override func clicked() { run() }
}
