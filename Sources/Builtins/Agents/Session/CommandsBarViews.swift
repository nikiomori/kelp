// The commands bar's parts: its header line, the grip that resizes it, and a command's row.
import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit
import WorkbenchKit

/// The bar's own line: the last command or the count, what can be done to a run under the pointer, and a chevron. A click
/// folds or unfolds.
@MainActor
final class Header: PointerControl {
    let row = CommandRow(), chevron = NSImageView()
    let stop = PointerButton(), toTab = PointerButton()
    var press: () -> Void = {}
    var contextMenu: (() -> NSMenu?)?
    private var run: Session?, always = false
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    init() {
        super.init(frame: .zero)
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .secondaryLabelColor
        for (b, title) in [(stop, String(localized: "Stop")), (toTab, String(localized: "Open in Tab"))] {
            b.title = title
            b.font = .ui(11)
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
    override func clicked() { press() }

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

/// The console's top edge: dragged, the console takes more of the pane or less. The terminal over it gets one resize, at
/// the end.
@MainActor
final class Grip: NSView {
    var dragged: (CGFloat) -> Void = { _ in }
    private var last: CGFloat = 0
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with e: NSEvent) {
        GhosttyTerminalView.holdSize(true)
        last = e.locationInWindow.y
    }
    override func mouseDragged(with e: NSEvent) {
        dragged(e.locationInWindow.y - last)
        last = e.locationInWindow.y
    }
    override func mouseUp(with e: NSEvent) { GhosttyTerminalView.holdSize(false) }
}

/// One command: its mark, the agent's words for it, what it runs in grey, and how long it took or has been running.
@MainActor
final class CommandRow: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("command")
    private let mark = StatusMark(size: 12)
    private let server = NSImageView(image: .symbol("play.fill", String(localized: "Serving a page")))
    /// The agent's words for it (else the command, else a title); then the command.
    private let lead = NSTextField(labelWithString: ""), command = NSTextField(labelWithString: ""),
        time = NSTextField(labelWithString: "")
    /// The mark's room, so the commands line up; a count goes without it.
    private let slot = NSView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        command.font = .uiMono(11)
        command.textColor = .secondaryLabelColor
        time.font = .uiDigits(11)
        time.textColor = .secondaryLabelColor
        for l in [lead, command] { l.lineBreakMode = .byTruncatingTail }
        lead.setContentCompressionResistancePriority(.init(260), for: .horizontal)   // short of room, the command goes first
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

    /// A command with a terminal: its name, what it last printed, or how it ended. Green ▶ while it serves a page.
    func show(run: Session, tail: String?, page: Int?, now: Date) {
        let live = run.status != .exited, serving = live && page != nil
        let status = live ? AgentStatus.working : Self.status(exit: run.exitCode)
        mark.status = serving ? nil : status
        server.isHidden = !serving
        slot.isHidden = false
        lead.font = .ui(11, weight: .medium)
        lead.stringValue = run.displayTitle
        command.textColor = status == .error ? .textRed : .secondaryLabelColor
        command.stringValue = serving ? "localhost:\(page ?? 0)" : live ? tail ?? "" : Self.ending(run, tail: tail)
        time.stringValue = shortSpan(
            (live ? now : run.statusAt ?? now).timeIntervalSince(run.createdAt), units: 2, smallest: .second)
        toolTip = run.argv.last ?? run.command
    }

    /// Exit 0 ✓, a signal it was stopped with (SIGINT, SIGKILL, SIGTERM) a grey ✕, anything else a failure.
    static func status(exit code: Int?) -> AgentStatus {
        switch code {
        case 0?: .done
        case 130?, 137?, 143?: .exited
        default: .error
        }
    }

    private static func ending(_ s: Session, tail: String?) -> String {
        guard status(exit: s.exitCode) != .exited else { return String(localized: "Stopped") }
        let code = String(localized: "exit code \(s.exitCode ?? 0)")
        return s.exitCode == 0 ? code : [code, tail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `c`, or (none) just `title`.
    func show(_ c: AgentCommand?, title: String = "", now: Date) {
        mark.status = c.map(Self.status)
        server.isHidden = true
        slot.isHidden = c == nil
        command.textColor = .secondaryLabelColor
        let words = c?.description.flatMap { $0.isEmpty ? nil : $0 }
        lead.font = c == nil ? .ui(11, weight: .semibold) : words == nil ? .uiMono(11) : .ui(11)
        lead.stringValue = words ?? c?.shortCommand ?? title
        command.stringValue = words == nil ? "" : c?.shortCommand ?? ""   // empty, it still pushes the time to the right
        time.stringValue = c.map { Self.time($0, now: now) } ?? ""
        toolTip = c.map { [$0.description, $0.command].compactMap { $0 }.joined(separator: "\n") }
    }

    /// Running spins; a fine end is a grey ✓, a failure red, one stopped a grey ✕. One moved to the background started fine.
    static func status(_ c: AgentCommand) -> AgentStatus {
        switch c.outcome {
        case nil: .working
        case .ok?, .background?: .done
        case .failed?: .error
        case .stopped?: .exited
        }
    }

    /// "12s", "1m 5s"; "in the background" for one whose end isn't told.
    static func time(_ c: AgentCommand, now: Date) -> String {
        if c.outcome == .background { return String(localized: "in the background") }
        return shortSpan((c.ended ?? now).timeIntervalSince(c.started), units: 2, smallest: .second)
    }
}
