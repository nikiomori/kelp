import AppKit
import Core
import DesignKit

/// The card a node of the Map shows under the pointer: the place, what was done there and by whom, when, and where to
/// go from it.
@MainActor
final class WorkCard: NSViewController {
    enum Action { case open, diff }
    private let place: AgentWork.Place, names: [String], icons: [NSImage?]
    private let act: (Action) -> Void

    init(
        place: AgentWork.Place, names: [String], icons: [NSImage?], opens: Bool = true, diffs: Bool = true,
        act: @escaping (Action) -> Void
    ) {
        self.place = place
        self.names = names
        self.icons = icons
        self.act = act
        self.opens = opens
        self.diffs = diffs
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private let opens: Bool, diffs: Bool

    override func loadView() {
        let isFile = place.kind == .file
        let title = NSTextField.label(
            isFile ? (place.name as NSString).lastPathComponent : place.name,
            font: .ui(TextSize.heading, weight: .semibold),
            truncation: .byTruncatingMiddle)
        var lines: [NSView] = [title]
        if isFile {
            var folder = (place.name as NSString).deletingLastPathComponent
            if let worktree = place.worktree {
                folder += (folder.isEmpty ? "" : " · ") + String(localized: "worktree \(WorkWords.worktree(worktree))")
            }
            if !folder.isEmpty {
                lines.append(
                    NSTextField.label(
                        folder, font: .ui(TextSize.caption), color: .secondaryLabelColor,
                        truncation: .byTruncatingMiddle))
            }
        }
        var did = [WorkWords.reads(place)]
        if place.edits > 0 { did.append(String(localized: "edited \(WorkWords.lines(place))")) }
        if place.byCommand && place.edits == 0 {
            did.append(String(localized: "changed by a command \(WorkWords.lines(place))"))
        }
        if let detail = place.detail, !isFile { did.append(detail) }
        lines.append(NSTextField.label(did.filter { !$0.isEmpty }.joined(separator: " · "), font: .ui(TextSize.body)))
        // One line per kind of agent: a dozen general-purpose subagents are one line, "general-purpose ×12".
        var seen: [String: (index: Int, count: Int)] = [:], order: [String] = []
        for agent in place.agents where names.indices.contains(agent) {
            let name = names[agent]
            if seen[name] == nil { order.append(name) }
            seen[name, default: (agent, 0)].count += 1
        }
        for name in order {
            guard let (index, count) = seen[name] else { continue }
            let logo = NSImageView(image: (icons.indices.contains(index) ? icons[index] : nil) ?? NSImage())
            let row = NSStackView(views: [
                logo, NSTextField.label(count > 1 ? "\(name) ×\(count)" : name, font: .ui(TextSize.body))
            ])
            row.spacing = Metrics.gap
            lines.append(row)
        }
        if let first = place.first, let last = place.last {
            let from = first.formatted(date: .omitted, time: .shortened)
            let to = last.formatted(date: .omitted, time: .shortened)
            let span = from == to ? from : "\(from) → \(to)"
            lines.append(NSTextField.label(span, font: .uiDigits(TextSize.caption), color: .secondaryLabelColor))
        }
        var buttons: [NSView] = []
        if isFile || opens && [.web, .tool, .outside, .own].contains(place.kind) {
            buttons.append(ClosureButton(title: String(localized: "Open")) { [act] in act(.open) })
        }
        if isFile, diffs, place.edits > 0 || place.byCommand {
            buttons.append(ClosureButton(title: String(localized: "Show Diff")) { [act] in act(.diff) })
        }
        for case let button as NSButton in buttons {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        if !buttons.isEmpty { lines.append(NSStackView(views: buttons)) }
        let column = NSStackView(views: lines)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.gapTight
        column.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        // As wide as its longest line, up to the card's width; a longer line is cut inside the margins, never past
        // them.
        let natural = lines.map(\.fittingSize.width).max() ?? 0
        let width = min(natural + 2 * Metrics.inset, Metrics.sheetWidth * 5 / 8)
        column.widthAnchor.constraint(equalToConstant: width).isActive = true
        for case let field as NSTextField in lines + lines.flatMap(\.subviews) {
            field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            field.lineBreakMode = .byTruncatingMiddle
        }
        for line in lines {
            line.widthAnchor.constraint(lessThanOrEqualToConstant: width - 2 * Metrics.inset).isActive = true
        }
        view = column
    }
}
