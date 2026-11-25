import AppKit
import Core
import DesignKit
import KelpKit

/// The column of sources on the left of Artifacts Overview, as Finder's sidebar is: every page, those waiting for the
/// user, the pinned and the archived ones, then each project with pages, each kind of page and each tag. A row says
/// how many pages it holds; Waiting for You says it in orange while something waits. Choosing a row shows its pages; a
/// tag's menu dresses it (Edit Tag…).
@MainActor
final class OverviewSourceList: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Row: Equatable {
        case heading(String)
        case source(OverviewSource)
    }

    let table = KeyTable()
    private let model: OverviewModel
    private(set) var rows: [Row] = []
    private var counts: [OverviewSource: Int] = [:]

    init(model: OverviewModel) {
        self.model = model
        super.init()
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "Sources"))
        table.menu = NSMenu()
        table.menu?.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow), case .source(.tag(let tag)) = rows[table.clickedRow] else {
            return
        }
        let model = self.model
        menu.add(String(localized: "Edit Tag…")) {
            Task {
                guard let style = await TagEditor.ask(tag, style: model.styles[tag]) else { return }
                model.setStyle(style == TagStyle() ? nil : style, for: tag)
            }
        }
    }

    /// Lists the sources for `pages`, keeping the chosen one chosen.
    func show(_ pages: [OverviewPage]) {
        let busy = model.busy
        // Now shows while an agent works with a page: an empty row would only say that none does.
        let fixed: [OverviewSource] =
            [.all] + (pages.contains { busy.contains($0.id) } ? [.now] : []) + [.waiting, .pinned, .archive]
        let projects = OverviewPages.projects(pages), kinds = OverviewPages.kinds(pages)
        var next = fixed.map(Row.source)
        // The project on screen stays listed while its pages are on their way.
        let shownProjects = projects + (model.source.project.map { projects.contains($0) ? [] : [$0] } ?? [])
        if !shownProjects.isEmpty {
            next += [.heading(String(localized: "Projects"))] + shownProjects.map { .source(.project($0)) }
        }
        if !kinds.isEmpty { next += [.heading(String(localized: "Kinds"))] + kinds.map { .source(.kind($0)) } }
        let tags = OverviewPages.tags(pages)
        if !tags.isEmpty { next += [.heading(String(localized: "Tags"))] + tags.map { .source(.tag($0)) } }
        counts = OverviewPages.counts(pages, next.compactMap(\.source), pinned: model.pinned, busy: busy)
        rows = next
        table.reloadData()
        // The chosen source's row, or none (Show's pages, a tag or Now emptied): a stale highlight would be a row a
        // click can't choose.
        if let at = rows.firstIndex(of: .source(model.source)) {
            if table.selectedRow != at { table.selectRowIndexes([at], byExtendingSelection: false) }
        } else {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let heading = rows[row].source == nil
        return ListRowView(lights: { _ in !heading })
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].source != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        TextSize.of(rows[row].source == nil ? Metrics.rowSection : Metrics.row)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(table.selectedRow), let source = rows[table.selectedRow].source,
            source != model.source
        else { return }
        model.source = source
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let text): return SectionHeading(text)
        case .source(let source): return cell(source)
        }
    }

    private func cell(_ source: OverviewSource) -> NSView {
        let name = NSTextField.label(title(source), font: .ui(TextSize.row))
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = counts[source] ?? 0
        let waits = source == .waiting && count > 0
        let number = NSTextField.label(
            count > 0 ? "\(count)" : "", font: .uiDigits(TextSize.caption, weight: waits ? .semibold : .regular),
            color: waits ? .textOrange : .secondaryLabelColor)
        number.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon(source), name, NSView(), number])
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(count > 0 ? "\(title(source)), \(count)" : title(source))
        return row
    }

    func title(_ source: OverviewSource) -> String {
        switch source {
        case .all: String(localized: "All")
        case .now: String(localized: "Now")
        case .waiting: String(localized: "Waiting for You")
        case .pinned: String(localized: "Pinned")
        case .archive: String(localized: "Archive")
        case .project(let repo): model.projectName(repo)
        case .kind(let kind): Artifacts.Kind(rawValue: kind).map(ArtifactStart.title) ?? String(localized: "Pages")
        case .tag(let tag): tag
        case .changed: String(localized: "Changed by the Agent")
        }
    }

    private func icon(_ source: OverviewSource) -> NSView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.widthAnchor.constraint(equalToConstant: 16).isActive = true
        view.heightAnchor.constraint(equalToConstant: 16).isActive = true
        if case .project(let repo) = source, let path = model.app.repo(repo)?.path {
            ProjectIcon.show(path, in: view, app: model.app)
            return view
        }
        if case .tag(let tag) = source, let emoji = model.styles[tag]?.emoji {
            let label = NSTextField.label(emoji, font: .ui(TextSize.row))
            label.alignment = .center
            label.widthAnchor.constraint(equalToConstant: 16).isActive = true
            return label
        }
        let symbol: String =
            switch source {
            case .all: "doc.richtext"
            case .now: "bolt"
            case .waiting: "checklist"
            case .pinned: "pin"
            case .archive: "archivebox"
            case .kind(let kind): ArtifactCells.symbol(kind)
            case .project: "folder"
            case .tag(let tag): model.styles[tag]?.symbol ?? "number"
            case .changed: "arrow.uturn.backward"
            }
        view.image = .symbol(symbol)
        view.symbolConfiguration = .chrome()
        if case .tag(let tag) = source {
            view.contentTintColor = model.styles[tag]?.color?.ns ?? .secondaryLabelColor
        } else {
            view.contentTintColor = .secondaryLabelColor
        }
        view.imageScaling = .scaleNone
        return view
    }
}

extension OverviewSourceList.Row {
    var source: OverviewSource? {
        if case .source(let source) = self { return source }
        return nil
    }
}

extension OverviewSource {
    var project: String? {
        if case .project(let repo) = self { return repo }
        return nil
    }
}
