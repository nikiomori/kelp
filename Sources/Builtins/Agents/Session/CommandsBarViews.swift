// The parts of the commands bar: its header line, the grip that resizes it, and a command's row.
import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit

/// The header line of the commands bar. It shows the last command or the count, the actions for the current run when
/// the pointer is over the line, and a chevron. A click on it folds or unfolds the bar.
@MainActor
final class Header: PointerControl {
    let row = CommandRow(), chevron = NSImageView()
    let stop = PointerButton(), toTab = PointerButton()
    var contextMenu: (() -> NSMenu?)?
    private var run: Session?, always = false
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    init() {
        super.init(frame: .zero)
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .secondaryLabelColor
        for (b, title) in [(stop, String(localized: "Stop")), (toTab, String(localized: "Open in Tab"))] {
            b.title = title
            b.font = .ui(TextSize.caption)
            b.padding = Metrics.gap
            b.restFill = .fillHover
            b.isHidden = true
        }
        let stack = NSStackView(views: [row, stop, toTab, chevron])
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: Metrics.inset)
        pin(stack)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func showActions(for run: Session?, always: Bool) {
        self.run = run
        self.always = always
        refreshPointer()
    }
    override func showPointer(hovering: Bool, pressed: Bool) {
        super.showPointer(hovering: hovering, pressed: pressed)
        toTab.isHidden = run == nil || !(hovering || always)
        stop.isHidden = toTab.isHidden || run?.status == .exited
    }
}

/// The top edge of the console. Dragging it gives the console more or less of the pane. The terminal above is resized
/// only once, when the drag ends.
@MainActor
final class Grip: NSView {
    var dragged: (CGFloat) -> Void = { _ in }
    private var last: CGFloat = 0
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {
        GhosttyTerminalView.holdSize(true)
        last = event.locationInWindow.y
    }
    override func mouseDragged(with event: NSEvent) {
        dragged(event.locationInWindow.y - last)
        last = event.locationInWindow.y
    }
    override func mouseUp(with event: NSEvent) { GhosttyTerminalView.holdSize(false) }
}

/// A row for one command. It shows the command's status mark, the agent's description of it, the command itself in
/// grey, and how long it took or has been running.
@MainActor
final class CommandRow: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("command")
    private let mark = StatusMark(size: 12)
    private let server = NSImageView(image: .symbol("play.fill", String(localized: "Serving a page")))
    /// `lead` shows the agent's description of the command (or else the command, or else a title), and `command` shows
    /// the command.
    private let lead = NSTextField(labelWithString: ""), command = NSTextField(labelWithString: ""),
        time = NSTextField(labelWithString: "")
    /// The space that holds the mark, so the commands line up. A row that shows a count has no slot.
    private let slot = NSView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        command.font = .uiMono(TextSize.caption)
        command.textColor = .secondaryLabelColor
        time.font = .uiDigits(TextSize.caption)
        time.textColor = .secondaryLabelColor
        for l in [lead, command] { l.lineBreakMode = .byTruncatingTail }
        lead.setContentCompressionResistancePriority(.init(260), for: .horizontal)   // the command is cut first
        command.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        command.setContentHuggingPriority(.init(1), for: .horizontal)   // the time sits at the right
        server.symbolConfiguration = .chrome(Metrics.iconTiny)
        server.contentTintColor = .systemGreen
        server.isHidden = true
        for v in [server, mark] { v.translatesAutoresizingMaskIntoConstraints = false }
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(mark)
        slot.addSubview(server)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: 12), slot.heightAnchor.constraint(equalToConstant: 12),
            mark.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            server.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            server.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
        ])
        let stack = NSStackView(views: [slot, lead, command, time])
        stack.spacing = Metrics.gapWide
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        pin(stack)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows a command that has its own terminal: its name, then what it last printed or how it ended. A green ▶
    /// replaces the mark while it serves a page.
    func show(run: Session, tail: String?, page: Int?, now: Date) {
        let live = run.status != .exited, serving = live && page != nil
        let status = live ? AgentStatus.working : Self.status(exit: run.exitCode)
        mark.status = serving ? nil : status
        server.isHidden = !serving
        slot.isHidden = false
        lead.font = .ui(TextSize.caption, weight: .medium)
        lead.stringValue = run.displayTitle
        command.textColor = status == .error ? .textRed : .secondaryLabelColor
        command.stringValue = serving ? "localhost:\(page ?? 0)" : live ? tail ?? "" : Self.ending(run, tail: tail)
        time.stringValue = shortSpan(
            (live ? now : run.statusAt ?? now).timeIntervalSince(run.createdAt), units: 2, smallest: .second)
        toolTip = run.argv.last ?? run.command
    }

    /// Returns the status for an exit code. Exit 0 is a ✓, and a stop by a signal (SIGINT, SIGKILL, SIGTERM) is a grey
    /// ✕. Any other code is a failure.
    static func status(exit code: Int?) -> AgentStatus {
        switch code {
        case 0?: .done
        case 130?, 137?, 143?: .exited
        default: .error
        }
    }

    private static func ending(_ session: Session, tail: String?) -> String {
        guard status(exit: session.exitCode) != .exited else { return String(localized: "Stopped") }
        let code = String(localized: "exit code \(session.exitCode ?? 0)")
        return session.exitCode == 0
            ? code : [code, tail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Shows a shell command, or just `title` when `agentCommand` is nil.
    func show(_ agentCommand: AgentCommand?, title: String = "", now: Date) {
        mark.status = agentCommand.map(Self.status)
        server.isHidden = true
        slot.isHidden = agentCommand == nil
        command.textColor = .secondaryLabelColor
        let words = agentCommand?.description.flatMap { $0.isEmpty ? nil : $0 }
        lead.font =
            agentCommand == nil
            ? .ui(TextSize.caption, weight: .semibold)
            : words == nil ? .uiMono(TextSize.caption) : .ui(TextSize.caption)
        lead.stringValue = words ?? agentCommand?.shortCommand ?? title
        // even when empty, the command field still pushes the time to the right
        command.stringValue = words == nil ? "" : agentCommand?.shortCommand ?? ""
        time.stringValue = agentCommand.map { Self.time($0, now: now) } ?? ""
        toolTip = agentCommand.map { [$0.description, $0.command].compactMap { $0 }.joined(separator: "\n") }
    }

    /// Returns the status mark of a shell command. A running command spins, one that ended well is a grey ✓, a failure
    /// is red, and a stopped one is a grey ✕. A command moved to the background counts as started well.
    static func status(_ agentCommand: AgentCommand) -> AgentStatus {
        switch agentCommand.outcome {
        case nil: .working
        case .ok?, .background?: .done
        case .failed?: .error
        case .stopped?: .exited
        }
    }

    /// Returns how long the command ran, such as "12s" or "1m 5s". A command moved to the background shows "in the
    /// background", because nothing reports when it ends.
    static func time(_ agentCommand: AgentCommand, now: Date) -> String {
        if agentCommand.outcome == .background { return String(localized: "in the background") }
        return shortSpan(
            (agentCommand.ended ?? now).timeIntervalSince(agentCommand.started), units: 2, smallest: .second)
    }
}
