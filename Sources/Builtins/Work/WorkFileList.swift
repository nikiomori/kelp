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
        // What goes after the name, the more needed first: the panel drops the last ones whole when it is narrow. The
        // folder first: it is what tells two files of one name apart.
        var extras: [NSView] = []
        // Two File.swift in two folders read apart only by their folders: each says where it is under the block.
        let folder = (place.name as NSString).deletingLastPathComponent
        if spansFolders, !folder.isEmpty {
            let shown = under.isEmpty ? folder : Paths.relative(folder, to: under) ?? folder
            if !shown.isEmpty {
                extras.append(
                    NSTextField.label(
                        shown, font: .ui(TextSize.caption), color: .tertiaryLabelColor, truncation: .byTruncatingMiddle)
                )
            }
        }
        let read = WorkWords.reads(place)
        if !read.isEmpty {
            extras.append(
                NSTextField.label(
                    (place.reads >= 3 ? "↻ " : "") + read, font: .ui(TextSize.caption), color: .secondaryLabelColor))
        }
        if place.byCommand && place.edits == 0 {
            extras.append(
                NSTextField.label(
                    String(localized: "by a command"), font: .ui(TextSize.caption), color: .secondaryLabelColor))
        }
        // The panel's own agent goes without saying; subagents and the agents it started are marked.
        let others = AgentMarks.of(place.agents, agents: agents)
        if !others.isEmpty { extras.append(marks(others)) }
        if let worktree = WorkWords.badged(place.worktree) { extras.append(Self.badge(worktree)) }
        let cell = FileRow(mark: mark, name: name, extras: extras, lines: Self.lines(place))
        cell.toolTip = place.name
        cell.setAccessibilityElement(true)
        cell.setAccessibilityLabel(
            WorkWords.describe(WorkNode(path: place.name, name: place.name, place: place), agents: names))
        return cell
    }

    /// The marks of who touched a place, as one piece: logos, then the subagents' mark and their count.
    private func marks(_ marks: [AgentMarks.Mark]) -> NSView {
        var views: [NSView] = []
        for mark in marks {
            switch mark {
            case .agent(let index):
                let logo = NSImageView(
                    image: WorkModel.icon(agents[index], app: app, size: Metrics.iconSmall) ?? NSImage())
                logo.toolTip = names.indices.contains(index) ? names[index] : nil
                views.append(logo)
            case .subagents(let list):
                let logo = NSImageView(image: WorkModel.subagentMark(Metrics.iconSmall) ?? NSImage())
                logo.toolTip = list.compactMap { names.indices.contains($0) ? names[$0] : nil }.joined(separator: ", ")
                views.append(logo)
                if list.count > 1 {
                    views.append(
                        NSTextField.label(
                            "×\(list.count)", font: .uiDigits(TextSize.caption), color: .secondaryLabelColor))
                }
            }
        }
        let group = NSStackView(views: views)
        group.spacing = Metrics.lineGap
        return group
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
        // Its fill drawn by the field, so it follows light and dark; the layer only rounds it.
        label.drawsBackground = true
        label.backgroundColor = .fillSelected
        label.wantsLayer = true
        label.layer?.cornerRadius = Metrics.radiusXS
        label.layer?.masksToBounds = true
        label.toolTip = String(localized: "Touched in the worktree \(worktree)")
        return label
    }

    /// "+18 −5" in the diff's colours.
    static func lines(_ place: AgentWork.Place) -> NSTextField {
        let text = GitFolders.changes(added: place.added, removed: place.removed)
        let field = NSTextField(labelWithAttributedString: text)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }
}

/// One file's row: its mark and name at the left, its lines at the right edge, and between them as many of `extras`
/// as fit whole, the first first (the rest are left out, never squeezed). The name is cut in the middle only when
/// nothing else is left to drop.
@MainActor
final class FileRow: NSView {
    private let mark: NSView, name: NSTextField, extras: [NSView], lines: NSView

    init(mark: NSView, name: NSTextField, extras: [NSView], lines: NSView) {
        (self.mark, self.name, self.extras, self.lines) = (mark, name, extras, lines)
        super.init(frame: .zero)
        for view in [mark, name, lines] + extras { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Which of `extras` show, as laid out last.
    private(set) var shown: Set<Int> = []

    override func layout() {
        super.layout()
        let gap = Metrics.gapTight, left = Metrics.inset, right = bounds.width - Metrics.inset
        func size(_ view: NSView) -> NSSize { view.fittingSize }
        func place(_ view: NSView, x: CGFloat, width: CGFloat) {
            let h = size(view).height
            view.frame = NSRect(x: x, y: ((bounds.height - h) / 2).rounded(), width: max(0, width), height: h)
        }
        let linesWidth = size(lines).width
        place(lines, x: right - linesWidth, width: linesWidth)
        let end = right - (linesWidth > 0 ? linesWidth + gap : 0)
        place(mark, x: left, width: size(mark).width)
        var x = left + size(mark).width + gap
        let nameWidth = size(name).width
        var room = end - x - nameWidth
        shown = []
        for (index, extra) in extras.enumerated() {
            let width = size(extra).width + gap
            guard width <= room else { continue }   // one too wide is left out; a smaller one after it may still fit
            room -= width
            shown.insert(index)
        }
        place(name, x: x, width: min(nameWidth, end - x))
        x += min(nameWidth, end - x) + gap
        for (index, extra) in extras.enumerated() {
            extra.isHidden = !shown.contains(index)
            guard shown.contains(index) else { continue }
            let width = size(extra).width
            place(extra, x: x, width: width)
            x += width + gap
        }
    }
}
