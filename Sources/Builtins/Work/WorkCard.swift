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

    init(place: AgentWork.Place, names: [String], icons: [NSImage?], act: @escaping (Action) -> Void) {
        self.place = place
        self.names = names
        self.icons = icons
        self.act = act
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

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
                folder += (folder.isEmpty ? "" : " · ") + String(localized: "worktree \(worktree)")
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
        for agent in place.agents where names.indices.contains(agent) {
            let logo = NSImageView(image: (icons.indices.contains(agent) ? icons[agent] : nil) ?? NSImage())
            let row = NSStackView(views: [logo, NSTextField.label(names[agent], font: .ui(TextSize.body))])
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
        if isFile || place.kind == .web {
            buttons.append(ClosureButton(title: String(localized: "Open")) { [act] in act(.open) })
        }
        if isFile, place.edits > 0 || place.byCommand {
            buttons.append(ClosureButton(title: String(localized: "Show Diff")) { [act] in act(.diff) })
        }
        for case let button as NSButton in buttons {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        if !buttons.isEmpty { lines.append(NSStackView(views: buttons)) }
        // Each line keeps its words unless the card would pass its width; then the longest gives way (cut in the middle
        // for a path). Without this the popover sizes itself to the narrowest the lines allow.
        for case let field as NSTextField in lines + lines.flatMap(\.subviews) {
            field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        let column = NSStackView(views: lines)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.gapTight
        column.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        column.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.sheetWidth * 5 / 8).isActive = true
        view = column
    }
}
