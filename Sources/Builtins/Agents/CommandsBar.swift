import AppKit
import Core
import DesignKit
import KelpKit

/// Under an agent's terminal: the commands its shell tool ran (`AgentCommand`, from its hooks). Folded, one line says the
/// last one (running: for how long; ended: how it went); a click unfolds the list of them, oldest first, and a click on
/// one shows what it printed. There from its first command on and never goes: a terminal that grew and shrank with each
/// would redraw the agent every time.
@MainActor
final class CommandsBar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let app: AppModel
    private let watched: Watched
    private let header = Header()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var height: NSLayoutConstraint?, listHeight: NSLayoutConstraint?
    private var commands: [AgentCommand] = []
    private var unfolded = false
    /// Ticks while one runs, for its time.
    private var clock: Timer?
    private let popover = NSPopover()
    /// Rows the list shows before it scrolls.
    private static let shownRows = 8
    private static var rowHeight: CGFloat { TextSize.of(Metrics.row) }

    /// `watch`: an agent, whose hooks tell its commands; a terminal's bar stays empty.
    init(session: String, app: AppModel, watch: Bool) {
        self.app = app
        watched = Watched(.commands, in: app)
        super.init(frame: .zero)
        let line = NSBox(); line.boxType = .separator
        let col = NSTableColumn(identifier: .init("c")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self; table.action = #selector(clickedRow)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        popover.behavior = .transient
        header.press = { [weak self] in self?.fold(self?.unfolded == true) }
        for v in [line, header, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let h = heightAnchor.constraint(equalToConstant: 0), lh = scroll.heightAnchor.constraint(equalToConstant: 0)
        height = h; listHeight = lh
        NSLayoutConstraint.activate([
            h, lh,
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.statusBar)),
            header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        isHidden = true
        guard watch else { return }
        // Off by default (Settings › Agents): off, it neither shows nor watches.
        let on = { [app] in app.settings.bool("agents.commandsBar") == true }
        track(owner: self) { on() } changed: { [weak self] in self?.watched.key = $0 ? session : nil }
        track(owner: self) { [app] in on() ? app.commands[session] ?? [] : nil } changed: { [weak self] in self?.show($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `nil`: switched off.
    private func show(_ list: [AgentCommand]?) {
        guard let list else {
            commands = []
            isHidden = true
            popover.close()
            table.reloadData()
            layOut()
            tick()
            return
        }
        guard !list.isEmpty || !commands.isEmpty else { return }   // a new background service starts its list over: the bar stays
        let atEnd = table.rows(in: table.visibleRect).upperBound >= commands.count
        commands = list
        isHidden = false
        table.reloadData()
        if atEnd, !list.isEmpty { table.scrollRowToVisible(list.count - 1) }
        layOut()
        tick()
    }

    /// Unfolds or folds the list; the terminal over it gives or takes the room at once (an animated one would redraw the
    /// agent at every step).
    private func fold(_ fold: Bool) {
        unfolded = !fold
        if fold { popover.close() }
        layOut()
        if unfolded, !commands.isEmpty { table.scrollRowToVisible(commands.count - 1) }
    }

    private func layOut() {
        let list = unfolded ? CGFloat(min(commands.count, Self.shownRows)) * Self.rowHeight + 4 : 0
        listHeight?.constant = list
        height?.constant = isHidden ? 0 : TextSize.of(Metrics.statusBar) + list
        showHeader(Date())
    }

    /// Folded, the last command; unfolded, how many there are.
    private func showHeader(_ now: Date) {
        let count = String(localized: "\(commands.count) commands")
        if unfolded || commands.isEmpty {
            header.row.show(nil, title: count, now: now)
        } else if let last = commands.last {
            header.row.show(last, now: now)
        }
        header.chevron.image = .symbol(unfolded ? "chevron.down" : "chevron.up", unfolded ? String(localized: "Hide the commands") : count)
        header.toolTip = unfolded ? String(localized: "Hide the commands") : String(localized: "Show the commands it ran (\(commands.count))")
        header.setAccessibilityLabel(header.toolTip)
    }

    /// Times move on while a command runs.
    private func tick() {
        let running = commands.contains { $0.outcome == nil }
        if running, clock == nil {
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.tick() }
            }
        } else if !running { clock?.invalidate(); clock = nil }
        let now = Date()
        showHeader(now)
        guard unfolded else { return }
        for r in commands.indices where commands[r].outcome == nil {
            (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? CommandRow)?.show(commands[r], now: now)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clock?.invalidate(); clock = nil } else { tick() }   // no clock for a tab out of sight
    }

    @objc private func clickedRow() {
        guard commands.indices.contains(table.clickedRow) else { return }
        let c = commands[table.clickedRow]
        popover.contentViewController = CommandOutput(c)
        popover.show(relativeTo: table.rect(ofRow: table.clickedRow), of: table, preferredEdge: .minY)
    }

    func numberOfRows(in t: NSTableView) -> Int { commands.count }
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let v = t.makeView(withIdentifier: CommandRow.id, owner: nil) as? CommandRow ?? CommandRow()
        v.show(commands[row], now: Date())
        return v
    }
}

/// The bar's own line: the last command or the count, and a chevron. A click folds or unfolds the list.
@MainActor
private final class Header: PointerControl {
    let row = CommandRow(), chevron = NSImageView()
    var press: () -> Void = {}

    init() {
        super.init(frame: .zero)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        let s = NSStackView(views: [row, chevron])
        s.spacing = Metrics.gap
        s.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: Metrics.inset)
        pin(s)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func clicked() { press() }
}

/// One command: its mark, the agent's words for it, what it runs in grey, and how long it took or has been running.
@MainActor
final class CommandRow: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("command")
    private let mark = StatusMark(size: 12)
    /// The agent's words for it (else the command, else a title); then the command.
    private let lead = NSTextField(labelWithString: ""), command = NSTextField(labelWithString: ""), time = NSTextField(labelWithString: "")
    /// The mark's room, so the commands line up; a count goes without it.
    private let slot = NSView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        command.font = .uiMono(11); command.textColor = .secondaryLabelColor
        time.font = .uiDigits(11); time.textColor = .secondaryLabelColor
        for l in [lead, command] { l.lineBreakMode = .byTruncatingTail }
        lead.setContentCompressionResistancePriority(.init(260), for: .horizontal)   // short of room, the command goes first
        command.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        command.setContentHuggingPriority(.init(1), for: .horizontal)   // the time sits at the right
        slot.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(mark)
        NSLayoutConstraint.activate([slot.widthAnchor.constraint(equalToConstant: 12), slot.heightAnchor.constraint(equalToConstant: 12),
                                     mark.centerXAnchor.constraint(equalTo: slot.centerXAnchor), mark.centerYAnchor.constraint(equalTo: slot.centerYAnchor)])
        let s = NSStackView(views: [slot, lead, command, time])
        s.spacing = Metrics.gapWide
        s.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        pin(s)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `c`, or (none) just `title`.
    func show(_ c: AgentCommand?, title: String = "", now: Date) {
        mark.status = c.map(Self.status)
        slot.isHidden = c == nil
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
