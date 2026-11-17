import AppKit
import Core
import DesignKit
import KelpKit

/// A popover over a command's row that shows a command an agent ran. It shows the whole command, how it ended, and the
/// end of what it printed (the last 4 KB, as the hook passed it on), for the user to read or copy.
@MainActor
final class CommandOutput: NSViewController {
    private let command: AgentCommand
    private static let width = Metrics.sheetWidth

    init(_ command: AgentCommand) {
        self.command = command
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let agentCommand = command
        let title = NSTextField(wrappingLabelWithString: agentCommand.command)
        title.font = .uiMono(TextSize.row)
        title.maximumNumberOfLines = 6
        title.preferredMaxLayoutWidth = Self.width - 2 * Metrics.inset   // wraps at this width, reporting its height
        title.isSelectable = true
        let said = NSTextField.label(
            [agentCommand.description, Self.outcome(agentCommand)].compactMap { $0 }.joined(separator: " · "),
            font: .ui(TextSize.caption), color: agentCommand.outcome == .failed ? .textRed : .secondaryLabelColor)
        let text = NSStackView(views: [title, said])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        text.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.gapWide, right: Metrics.inset)
        text.setHuggingPriority(.required, for: .vertical)
        let line = NSBox()
        line.boxType = .separator
        let stack = NSStackView(views: [text, line, output()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for x in stack.arrangedSubviews { x.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
        preferredContentSize = stack.fittingSize   // without this the popover keeps its own size, whatever the text
    }

    /// Returns what the command printed, scrolled to its end, or a line saying why there is nothing to show.
    private func output() -> NSView {
        guard let out = command.output else {
            let none = NSTextField(
                labelWithString: command.outcome == nil
                    ? String(localized: "What it prints shows when it ends.")
                    : String(localized: "It printed nothing."))
            none.font = .ui(TextSize.caption)
            none.textColor = .secondaryLabelColor
            let box = NSStackView(views: [none])
            box.edgeInsets = NSEdgeInsets(
                top: Metrics.gapWide, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
            return box
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        // The view is as tall as the output, up to 300 pt.
        let lines = CGFloat(out.reduce(into: 1) { n, ch in if ch == "\n" { n += 1 } })
        scroll.heightAnchor.constraint(
            equalToConstant: min(300, lines * ceil(NSFont.uiMono(TextSize.caption).boundingRectForFont.height) + 12)
        ).isActive = true
        if let log = scroll.documentView as? NSTextView {
            log.isEditable = false
            log.font = .uiMono(TextSize.caption)
            log.textColor = .labelColor
            log.textContainerInset = NSSize(width: 6, height: 6)
            log.drawsBackground = false
            log.string = out
            log.scrollToEndOfDocument(nil)
        }
        return scroll
    }

    /// Returns how the command went, such as "Exit code 1", "Stopped" or "Running in the background".
    static func outcome(_ agentCommand: AgentCommand) -> String {
        switch agentCommand.outcome {
        case nil: String(localized: "Running for \(CommandRow.time(agentCommand, now: Date()))")
        case .ok?: String(localized: "Done in \(CommandRow.time(agentCommand, now: Date()))")
        case .failed?: agentCommand.exitCode.map { String(localized: "Exit code \($0)") } ?? String(localized: "Failed")
        case .stopped?: String(localized: "Stopped")
        case .background?: String(localized: "Running in the background")
        }
    }
}
