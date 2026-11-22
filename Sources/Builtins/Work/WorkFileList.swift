import AppKit
import Core
import DesignKit
import KelpKit

/// The files under the block picked in the layers: edited first, then by how often they were read, each with its mark,
/// its worktree, who touched it and its lines. A click opens the file beside the agent; with Option, the turn's diff.
@MainActor
final class WorkFileList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = KeyTable()
    private(set) lazy var scroll = table.plainList("files")
    var onOpen: (AgentWork.Place, _ diff: Bool) -> Void = { _, _ in }
    private var rows: [AgentWork.Place] = []
    /// The block picked: a file's folder is shown below it (grey, after the name) when the list spans folders.
    private var under = ""
    private var spansFolders = false
    private var names: [String] = [], agents: [AgentWork.Agent] = []
    private weak var app: AppModel?

    override init() {
        super.init()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = TextSize.of(Metrics.row)
        table.target = self
        table.action = #selector(clicked)
        table.onReturn = { [weak self] in self?.clicked() }
    }

    func show(_ node: WorkNode, names: [String], app: AppModel, agents: [AgentWork.Agent]) {
        let files = node.files.compactMap(\.place).sorted { a, b in
            let (ea, eb) = (a.edits > 0 || a.byCommand, b.edits > 0 || b.byCommand)
            if ea != eb { return ea }
            if a.reads != b.reads { return a.reads > b.reads }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        self.app = app
        self.agents = agents
        let folders = Set(files.map { ($0.name as NSString).deletingLastPathComponent })
        guard files != rows || names != self.names || under != node.path else { return }
        under = node.path
        spansFolders = folders.count > 1
        rows = files
        self.names = names
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { tableView.listRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let place = rows[row]
        let mark = PlaceMark()
        mark.kind = place.edits > 0 || place.byCommand ? .edit : .read
        let name = NSTextField.label(
            (place.name as NSString).lastPathComponent, font: .ui(TextSize.row), truncation: .byTruncatingMiddle)
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)   // the folder gives way first
        var parts: [NSView] = [mark, name]
        // Two File.swift in two folders read apart only by their folders: each says where it is under the block.
        let folder = (place.name as NSString).deletingLastPathComponent
        if spansFolders, !folder.isEmpty {
            let shown = under.isEmpty ? folder : Paths.relative(folder, to: under) ?? folder
            if !shown.isEmpty {
                parts.append(
                    NSTextField.label(
                        shown, font: .ui(TextSize.caption), color: .tertiaryLabelColor, truncation: .byTruncatingMiddle)
                )
            }
        }
        if let worktree = place.worktree { parts.append(Self.badge(worktree)) }
        for mark in AgentMarks.of(place.agents, agents: agents) {
            switch mark {
            case .agent(let index):
                let logo = NSImageView(
                    image: WorkModel.icon(agents[index], app: app, size: Metrics.iconSmall) ?? NSImage())
                logo.toolTip = names.indices.contains(index) ? names[index] : nil
                parts.append(logo)
            case .subagents(let list):
                let logo = NSImageView(image: WorkModel.subagentMark(Metrics.iconSmall) ?? NSImage())
                logo.toolTip = list.compactMap { names.indices.contains($0) ? names[$0] : nil }.joined(separator: ", ")
                parts.append(logo)
                if list.count > 1 {
                    parts.append(
                        NSTextField.label(
                            "×\(list.count)", font: .uiDigits(TextSize.caption), color: .secondaryLabelColor))
                }
            }
        }
        let read = WorkWords.reads(place)
        let loop = place.reads >= 3 ? "↻ " : ""
        if !read.isEmpty {
            parts.append(NSTextField.label(loop + read, font: .ui(TextSize.caption), color: .secondaryLabelColor))
        }
        if place.byCommand && place.edits == 0 {
            parts.append(
                NSTextField.label(
                    String(localized: "by a command"), font: .ui(TextSize.caption), color: .secondaryLabelColor))
        }
        // The room left goes to a spacer, so the lines always sit at the right edge.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        parts.append(spacer)
        parts.append(Self.lines(place))
        let cell = NSStackView(views: parts)
        cell.spacing = Metrics.gapTight
        cell.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        cell.toolTip = place.name
        cell.setAccessibilityElement(true)
        cell.setAccessibilityLabel(
            WorkWords.describe(WorkNode(path: place.name, name: place.name, place: place), agents: names))
        return cell
    }

    @objc private func clicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return }
        onOpen(rows[row], NSEvent.modifierFlags.contains(.option))
    }

    /// The worktree a file was touched in, as a grey chip.
    static func badge(_ worktree: String) -> NSView {
        let label = NSTextField.label(
            "⎇ " + WorkWords.worktree(worktree), font: .ui(TextSize.micro), color: .secondaryLabelColor)
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.fillSelected.cgColor
        label.layer?.cornerRadius = Metrics.radiusXS
        label.toolTip = String(localized: "Touched in the worktree \(worktree)")
        return label
    }

    /// "+18 −5" in the diff's colours.
    static func lines(_ place: AgentWork.Place) -> NSTextField {
        let text = NSMutableAttributedString()
        let font = NSFont.uiDigits(TextSize.caption)
        if place.added > 0 {
            text.append(
                .init(string: "+\(place.added)", attributes: [.font: font, .foregroundColor: NSColor.textGreen]))
        }
        if place.removed > 0 {
            if place.added > 0 { text.append(.init(string: " ")) }
            text.append(
                .init(string: "−\(place.removed)", attributes: [.font: font, .foregroundColor: NSColor.textRed]))
        }
        let field = NSTextField(labelWithAttributedString: text)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }
}
