import AppKit
import Core
import DesignKit
import KelpKit

/// Artifacts Overview's pages as cards under the panel's day headings, as Finder's icon view shows files: each card
/// is a picture of the page (`ArtifactPictures`), its title (bold until opened) and one quiet line. A click chooses a
/// card, a double click or Return opens it, Space shows it in Quick Look, and a right click shows the page's menu.
@MainActor
final class OverviewGrid: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    let collection = OverviewCollection()
    let scroll = NSScrollView()
    private let model: OverviewModel
    private(set) var sections: [(title: String, pages: [OverviewPage])] = []
    var onOpen: (OverviewPage) -> Void = { _ in }

    /// The narrowest a card gets before a column goes; the gaps between cards and around them.
    private static let narrowest: CGFloat = 190, gap: CGFloat = 16, lineGap: CGFloat = 18
    private static let card = NSUserInterfaceItemIdentifier("card"), heading = NSUserInterfaceItemIdentifier("day")

    init(model: OverviewModel) {
        self.model = model
        super.init()
        let layout = WidthLayout()
        layout.minimumInteritemSpacing = Self.gap
        layout.minimumLineSpacing = Self.lineGap
        layout.sectionInset = NSEdgeInsets(
            top: Metrics.gap, left: Metrics.pageInset, bottom: Metrics.blockGap, right: Metrics.pageInset)
        layout.headerReferenceSize = NSSize(width: 0, height: TextSize.of(Metrics.rowSection))
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.register(OverviewCard.self, forItemWithIdentifier: Self.card)
        collection.register(
            OverviewHeading.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: Self.heading)
        collection.dataSource = self
        collection.delegate = self
        collection.setAccessibilityLabel(String(localized: "Pages"))
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
    }

    func show(_ sections: [(title: String, pages: [OverviewPage])]) {
        let chosen = selected?.id
        self.sections = sections
        collection.reloadData()
        if let chosen, let path = indexPath(of: chosen) {
            collection.selectionIndexPaths = [path]
        }
    }

    var selected: OverviewPage? { collection.selectionIndexPaths.first.flatMap(page) }

    func page(_ path: IndexPath) -> OverviewPage? {
        guard sections.indices.contains(path.section), sections[path.section].pages.indices.contains(path.item)
        else { return nil }
        return sections[path.section].pages[path.item]
    }
    private func indexPath(of id: String) -> IndexPath? {
        for (s, section) in sections.enumerated() {
            if let i = section.pages.firstIndex(where: { $0.id == id }) { return IndexPath(item: i, section: s) }
        }
        return nil
    }

    /// Puts each card's picture in once it is drawn, without building the cards again.
    func refreshPictures() {
        for case let card as OverviewCard in collection.visibleItems() { card.showPicture(model) }
    }

    // MARK: Data

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].pages.count
    }
    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let card = collectionView.makeItem(withIdentifier: Self.card, for: indexPath)
        if let card = card as? OverviewCard, let page = page(indexPath) { card.show(page, model: model) }
        return card
    }
    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath
    ) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.heading, for: indexPath)
        (view as? OverviewHeading)?.show(sections[indexPath.section].title)
        return view
    }

    func collectionView(
        _ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard let page = page(indexPath) else { return }
        model.pictures.want(page.item, dark: collection.isDark)
    }
    func collectionView(
        _ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard let page = page(indexPath) else { return }
        model.pictures.unwant(page.item, dark: collection.isDark)
    }

    /// As many columns as fit cards no narrower than `narrowest`, sharing the width; the picture keeps the card's
    /// proportions, with the title and its line under it.
    func collectionView(
        _ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let width = collectionView.bounds.width - 2 * Metrics.pageInset
        let columns = max(1, floor((width + Self.gap) / (Self.narrowest + Self.gap)))
        let card = floor((width - (columns - 1) * Self.gap) / columns)
        return NSSize(width: card, height: OverviewCard.height(width: card))
    }
}

/// A flow layout that lays the cards out again when the grid's width changes, so the columns follow the pane.
private final class WidthLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != (collectionView?.bounds.width ?? newBounds.width)
    }
}

/// The grid's own keys and clicks, as Finder's: Return opens the chosen card, Space shows it in Quick Look, a double
/// click opens the card under it, and a right click chooses the card under it and shows its menu.
@MainActor
final class OverviewCollection: NSCollectionView {
    var onReturn: () -> Void = {}, onSpace: () -> Void = {}
    var onDoubleClick: (IndexPath) -> Void = { _ in }
    var menuFor: (IndexPath) -> NSMenu? = { _ in nil }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.isDisjoint(with: [.command, .option, .control])
        if [36, 76].contains(event.keyCode) {
            onReturn()
        } else if event.keyCode == 49, plain {
            onSpace()
        } else {
            super.keyDown(with: event)
        }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        else { return }
        onDoubleClick(path)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !selectionIndexPaths.contains(path) { selectionIndexPaths = [path] }
        return menuFor(path)
    }
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// A day's heading over its cards, as the panel's.
final class OverviewHeading: NSView, NSCollectionViewElement {
    private var heading: SectionHeading?
    func show(_ title: String) {
        heading?.removeFromSuperview()
        let next = SectionHeading(title)
        next.translatesAutoresizingMaskIntoConstraints = false
        addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.pageInset - Metrics.inset),
            next.trailingAnchor.constraint(equalTo: trailingAnchor),
            next.topAnchor.constraint(equalTo: topAnchor), next.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        heading = next
    }
}
