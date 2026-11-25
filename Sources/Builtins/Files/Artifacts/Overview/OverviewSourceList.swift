import AppKit
import Core
import DesignKit
import KelpKit

/// The column of sources on the left of Artifacts Overview, as Finder's sidebar is: every page, those waiting for the
/// user, the pinned and the archived ones, then each project with pages and each kind of page. A row says how many
/// pages it holds; Waiting for You says it in orange while something waits. Choosing a row shows its pages.
@MainActor
final class OverviewSourceList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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
    }

    /// Lists the sources for `pages`, keeping the chosen one chosen.
    func show(_ pages: [OverviewPage]) {
        let fixed: [OverviewSource] = [.all, .waiting, .pinned, .archive]
        let projects = OverviewPages.projects(pages), kinds = OverviewPages.kinds(pages)
        var next = fixed.map(Row.source)
        // The project on screen stays listed while its pages are on their way.
        let shownProjects = projects + (model.source.project.map { projects.contains($0) ? [] : [$0] } ?? [])
        if !shownProjects.isEmpty {
            next += [.heading(String(localized: "Projects"))] + shownProjects.map { .source(.project($0)) }
        }
        if !kinds.isEmpty { next += [.heading(String(localized: "Kinds"))] + kinds.map { .source(.kind($0)) } }
        counts = OverviewPages.counts(
            pages, next.compactMap(\.source), pinned: model.pinned, archived: model.archived)
        rows = next
        table.reloadData()
        if let at = rows.firstIndex(of: .source(model.source)), table.selectedRow != at {
            table.selectRowIndexes([at], byExtendingSelection: false)
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
        case .waiting: String(localized: "Waiting for You")
        case .pinned: String(localized: "Pinned")
        case .archive: String(localized: "Archive")
        case .project(let repo): model.projectName(repo)
        case .kind(let kind): Artifacts.Kind(rawValue: kind).map(ArtifactStart.title) ?? String(localized: "Pages")
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
        let symbol: String =
            switch source {
            case .all: "doc.richtext"
            case .waiting: "checklist"
            case .pinned: "pin"
            case .archive: "archivebox"
            case .kind(let kind): ArtifactCells.symbol(kind)
            case .project: "folder"
            }
        view.image = .symbol(symbol)
        view.symbolConfiguration = .chrome()
        view.contentTintColor = .secondaryLabelColor
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
