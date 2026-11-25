import AppKit
import Core
import DesignKit
import KelpKit

/// One page on Artifacts Overview's grid: its picture (a grey fill until it is drawn, or for a page with none), its
/// title in bold until it is opened, and one quiet line. The line says what the panel's second line says when there
/// is news (the agent writing it, marks to check, a review's answers), and otherwise the page's project and when it
/// last changed. Its tags come between the two, on their colours. A page on claude.ai carries Claude's mark, as its
/// row in the panel does. The card lights up under the pointer and takes the selection's colour when chosen.
@MainActor
final class OverviewCard: NSCollectionViewItem {
    private let picture = PictureView()
    private let kind = NSImageView()
    private let name = NSTextField.label("", font: .ui(TextSize.row))
    private let line = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    private let mark = NSImageView()
    private let tags = NSStackView()
    private var shown: OverviewPage?

    /// How tall a card of `width` is: the picture at the panel card's proportions, then the title, the tags and the
    /// line. Every card leaves room for tags, so the cards of a row line up.
    static func height(width: CGFloat) -> CGFloat {
        let size = ArtifactCard.size
        return ceil(width * size.height / size.width) + Metrics.gap + TextSize.of(Metrics.rowTwoLine)
            + TextSize.of(Metrics.countCapsule) + Metrics.lineGap
    }

    override func loadView() {
        let card = CardView()
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = Metrics.radiusSM
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = 1
        picture.tint()
        kind.symbolConfiguration = .chrome()
        kind.contentTintColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        line.lineBreakMode = .byTruncatingTail
        for label in [name, line] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        let title = NSStackView(views: [kind, name])
        title.spacing = Metrics.gap
        let under = NSStackView(views: [mark, line])
        under.spacing = Metrics.lineGap
        under.detachesHiddenViews = true
        tags.detachesHiddenViews = true
        let words = NSStackView(views: [title, tags, under])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Metrics.lineGap
        for view in [picture, words] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        let size = ArtifactCard.size
        let pad = Metrics.gap
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            picture.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            picture.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: size.height / size.width),
            words.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: Metrics.gap),
            words.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            words.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -pad),
            kind.widthAnchor.constraint(equalToConstant: 16)
        ])
        view = card
    }

    override var isSelected: Bool { didSet { (view as? CardView)?.chosen = isSelected } }

    func show(_ page: OverviewPage, model: OverviewModel) {
        shown = page
        let item = page.item, app = model.app
        kind.image = .symbol(ArtifactCells.symbol(item.type))
        name.stringValue = model.title(page)
        name.font = .ui(TextSize.row, weight: ArtifactSeen.isNew(item, app) ? .semibold : .regular)
        let note = ArtifactActions.note(item, app)
        let when = shortAgo(Date(timeIntervalSince1970: page.time))
        line.stringValue = note?.text ?? "\(model.projectName(page.repo)) · \(when)"
        line.textColor = note?.waits == true ? .textOrange : .secondaryLabelColor
        tags.setViews([TagCapsule.line(item.tags ?? [], styles: model.styles)], in: .leading)
        tags.isHidden = item.tags?.isEmpty != false
        mark.image = item.url == nil ? nil : app.catalog.icon(Session.claudeAgent, size: Metrics.iconSmall)
        mark.isHidden = mark.image == nil
        mark.toolTip = String(localized: "On claude.ai: opens in your browser")
        view.toolTip = item.title
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("\(item.title), \(line.stringValue)")
        showPicture(model)
    }

    /// Puts in the page's picture once it is drawn.
    func showPicture(_ model: OverviewModel) {
        guard let item = shown?.item else { return }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = model.pictures.image(item, dark: dark)
        guard picture.image !== image else { return }
        if picture.image == nil, image != nil, view.window != nil { picture.crossfade() }
        picture.image = image
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        picture.image = nil
        shown = nil
    }
}

/// A card's ground: clear at rest, the hover fill under the pointer, the selection's quiet colour when chosen, with
/// the accent around it while the grid has the keys.
private final class CardView: NSView {
    var chosen = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Metrics.radiusMD
        let focused = window?.firstResponder is NSCollectionView && window?.isKeyWindow == true
        layer?.backgroundColor = (chosen ? NSColor.fillSelected : hovering ? .fillHover : .clear).cgColor
        layer?.borderWidth = chosen && focused ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
