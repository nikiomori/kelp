import AppKit
import Core
import DesignKit
import KelpKit

/// A command an agent ran, in a popover over its row: the whole command, how it went, and the end of what it printed
/// (the last 4 KB, as the hook gave it), to read or copy.
@MainActor
final class CommandOutput: NSViewController {
    private let command: AgentCommand
    private static let width = Metrics.sheetWidth

    init(_ c: AgentCommand) {
        command = c
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let c = command
        let title = NSTextField(wrappingLabelWithString: c.command)
        title.font = .uiMono(12)
        title.maximumNumberOfLines = 6
        title.preferredMaxLayoutWidth = Self.width - 2 * Metrics.inset   // wraps at the popover's width, and says how tall that is
        title.isSelectable = true
        let said = NSTextField(labelWithString: [c.description, Self.outcome(c)].compactMap { $0 }.joined(separator: " · "))
        said.font = .ui(11)
        said.textColor = c.outcome == .failed ? .textRed : .secondaryLabelColor
        said.lineBreakMode = .byTruncatingTail
        said.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, said])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        text.edgeInsets = NSEdgeInsets(top: Metrics.inset, left: Metrics.inset, bottom: Metrics.gapWide, right: Metrics.inset)
        text.setHuggingPriority(.required, for: .vertical)
        let line = NSBox(); line.boxType = .separator
        let v = NSStackView(views: [text, line, output()])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0
        for x in v.arrangedSubviews { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = v
        preferredContentSize = v.fittingSize   // the popover's own size otherwise, whatever the text
    }

    /// What it printed, scrolled to its end; or why there's nothing to show.
    private func output() -> NSView {
        guard let out = command.output else {
            let none = NSTextField(labelWithString: command.outcome == nil ? String(localized: "What it prints shows when it ends.")
                                                                            : String(localized: "It printed nothing."))
            none.font = .ui(11); none.textColor = .secondaryLabelColor
            let box = NSStackView(views: [none])
            box.edgeInsets = NSEdgeInsets(top: Metrics.gapWide, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
            return box
        }
        let log = NSTextView()
        log.isEditable = false
        log.font = .uiMono(11)
        log.textColor = .labelColor
        log.textContainerInset = NSSize(width: 6, height: 6)
        log.drawsBackground = false
        log.isVerticallyResizable = true
        log.isHorizontallyResizable = false
        log.autoresizingMask = .width
        log.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        log.textContainer?.widthTracksTextView = true
        log.string = out
        let scroll = NSScrollView()
        scroll.documentView = log
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // As tall as what it printed, up to 300 pt.
        let lines = CGFloat(out.reduce(into: 1) { n, ch in if ch == "\n" { n += 1 } })
        scroll.heightAnchor.constraint(equalToConstant: min(300, lines * ceil(NSFont.uiMono(11).boundingRectForFont.height) + 12)).isActive = true
        log.scrollToEndOfDocument(nil)
        return scroll
    }

    /// "Exit code 1", "Stopped", "Running in the background"…
    static func outcome(_ c: AgentCommand) -> String {
        switch c.outcome {
        case nil: String(localized: "Running for \(CommandRow.time(c, now: Date()))")
        case .ok?: String(localized: "Done in \(CommandRow.time(c, now: Date()))")
        case .failed?: c.exitCode.map { String(localized: "Exit code \($0)") } ?? String(localized: "Failed")
        case .stopped?: String(localized: "Stopped")
        case .background?: String(localized: "Running in the background")
        }
    }
}
