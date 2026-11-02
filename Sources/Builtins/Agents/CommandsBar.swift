import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit
import WorkbenchKit

/// Under an agent's terminal: what it ran. Its commands in a tab of their own making (`Session.startedBy`, `kelp session
/// new --cmd`), and what its shell tool ran (`AgentCommand`, from its hooks, with Settings › Agents on). Folded, one line
/// says the command running, else the last one; a click unfolds the list, and a command's own terminal or what a shell
/// command printed. There from its first command on and never goes: a terminal that grew and shrank with each would redraw
/// the agent every time.
@MainActor
final class CommandsBar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// One row: a command with a terminal, or one the shell tool ran.
    private enum Item {
        case run(Session), command(AgentCommand)
        var started: Date {
            switch self {
            case .run(let s): s.createdAt
            case .command(let c): c.started
            }
        }
    }

    private let app: AppModel
    private let watched: Watched
    private let header = Header()
    private let grip = Grip()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let consoleBox = NSView()
    private var height: NSLayoutConstraint?, listHeight: NSLayoutConstraint?, consoleHeight: NSLayoutConstraint?
    private var commands: [AgentCommand] = []
    private var runs: [Session] = []
    private var items: [Item] = []
    /// The last line each run printed.
    private var tails: [String: String] = [:]
    private var finalTails: Set<String> = []
    private var reading = false
    private var unfolded = false
    /// The run shown unfolded, in a terminal of its own, and how much of the pane it takes.
    private var console: PaneView?
    private var share: CGFloat = 0.4
    private var escape: Any?
    /// The console closed from the keyboard: the keys go back to the agent.
    var onClosed: (() -> Void)?
    /// Ticks while one runs, for its time.
    private var clock: Timer?
    private let popover = NSPopover()
    /// Rows the list shows before it scrolls, alone and over a console.
    private static let shownRows = 8, rowsOverConsole = 4
    private static var rowHeight: CGFloat { TextSize.of(Metrics.row) }

    /// `watch`: an agent, whose hooks and commands fill it; a terminal's bar stays empty.
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
        table.menu = NSMenu(); table.menu?.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        popover.behavior = .transient
        consoleBox.clipsToBounds = true
        header.press = { [weak self] in self?.fold(self?.unfolded == true) }
        header.contextMenu = { [weak self] in self?.headerMenu() }
        header.stop.onClick = { [weak self] in if let s = self?.current { self?.stop(s) } }
        header.toTab.onClick = { [weak self] in if let s = self?.current { self?.moveToTab(s) } }
        grip.isHidden = true
        grip.dragged = { [weak self] in self?.drag(by: $0) }
        for v in [line, header, scroll, consoleBox, grip] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let h = heightAnchor.constraint(equalToConstant: 0), lh = scroll.heightAnchor.constraint(equalToConstant: 0)
        let ch = consoleBox.heightAnchor.constraint(equalToConstant: 0)
        (height, listHeight, consoleHeight) = (h, lh, ch)
        NSLayoutConstraint.activate([
            h, lh, ch,
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.statusBar)),
            header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            consoleBox.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            consoleBox.leadingAnchor.constraint(equalTo: leadingAnchor), consoleBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            grip.topAnchor.constraint(equalTo: topAnchor), grip.heightAnchor.constraint(equalToConstant: Metrics.gap),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor), grip.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        isHidden = true
        guard watch else { return }
        // Off by default (Settings › Agents): off, it neither shows nor watches the hooks' commands.
        let on = { [app] in app.settings.bool("agents.commandsBar") == true }
        track(owner: self) { on() } changed: { [weak self] in self?.watched.key = $0 ? session : nil }
        track(owner: self) { [app] in on() ? app.commands[session] ?? [] : nil } changed: { [weak self] in self?.show($0) }
        track(owner: self) { [app] in
            let inTabs = app.uiState.strings(Session.inTabKey)
            return app.sessions.filter { $0.startedBy == session && !inTabs.contains($0.id) && app.sessions.owner(of: $0) != nil }
        } changed: { [weak self] in self?.show(runs: $0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `nil`: switched off.
    private func show(_ list: [AgentCommand]?) {
        guard let list else {
            commands = []
            popover.close()
            reload(keeping: false)
            return
        }
        guard !list.isEmpty || !items.isEmpty else { return }   // a new background service starts its list over: the bar stays
        commands = list
        reload(keeping: true)
    }

    private func show(runs list: [Session]) {
        runs = list.sorted { $0.createdAt < $1.createdAt }
        if let c = console {
            if let s = app.session(c.sessionId), list.contains(where: { $0.id == s.id }) { c.update(s) } else { closeConsole() }
        }
        reload(keeping: true)
    }

    /// `keeping`: an empty list leaves the bar where it is, so the terminal over it doesn't move.
    private func reload(keeping: Bool) {
        let atEnd = table.rows(in: table.visibleRect).upperBound >= items.count
        items = (runs.map(Item.run) + commands.map(Item.command)).sorted { $0.started < $1.started }
        if !items.isEmpty { isHidden = false } else if !keeping { isHidden = true }
        table.reloadData()
        if atEnd, !items.isEmpty { table.scrollRowToVisible(items.count - 1) }
        layOut()
        tick()
    }

    /// The run the folded line speaks of: the newest still running, else the last thing it ran if that's a run.
    private var current: Session? {
        runs.last { $0.status != .exited } ?? { if case .run(let s)? = items.last { s } else { nil } }()
    }

    /// Unfolds or folds the list and the console; the terminal over it keeps its size until they stop, or it would redraw
    /// the agent at every step.
    private func fold(_ fold: Bool) {
        unfolded = !fold
        if fold { popover.close(); closeConsole() } else if let s = current { open(s) }
        layOut(animated: true)
        header.chevron.turn(from: .pi)
        if unfolded, !items.isEmpty { table.scrollRowToVisible(items.count - 1) }
    }

    /// `s` in the console. The keys stay where they are; a click in it takes them, Esc gives them back.
    private func open(_ s: Session) {
        guard console?.sessionId != s.id else { return }
        console?.removeFromSuperview()
        let p = PaneView(session: s, app: app, embedded: true)
        console = p
        consoleBox.pin(p)
        grip.isHidden = false
        guard escape == nil else { return }
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let self, let r = window?.firstResponder as? NSView, r.isDescendant(of: consoleBox) else { return e }
            fold(true)
            onClosed?()
            return nil
        }
    }

    private func closeConsole() {
        console?.removeFromSuperview(); console = nil
        grip.isHidden = true
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }

    private func stop(_ s: Session) { Task { await app.call(SessionKill(id: s.id)) } }
    private func moveToTab(_ s: Session) {
        if console?.sessionId == s.id { fold(true) }
        app.scripts.openInTab(s.id)
        show(runs: runs.filter { $0.id != s.id })
        if items.isEmpty { reload(keeping: false) }
    }

    /// The pane changed height: the console keeps its share of it.
    func paneResized() { if console != nil { layOut() } }

    private func drag(by dy: CGFloat) {
        guard let pane = superview?.bounds.height, pane > 0, let now = consoleHeight?.constant else { return }
        share = min(0.8, max(0.15, (now + dy) / pane))
        layOut()
    }

    private func layOut(animated: Bool = false) {
        var list: CGFloat = 0, shown: CGFloat = 0
        if unfolded {
            let rows = console == nil ? min(items.count, Self.shownRows) : items.count > 1 ? min(items.count, Self.rowsOverConsole) : 0
            list = rows == 0 ? 0 : CGFloat(rows) * Self.rowHeight + 4
            if console != nil, let pane = superview?.bounds.height { shown = (pane * share).rounded() }
        }
        let bar = isHidden ? 0 : TextSize.of(Metrics.statusBar) + list + shown
        if animated, !Motion.reduced, window != nil, let listHeight, let height, let consoleHeight {
            GhosttyTerminalView.holdSize(true)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.base
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                listHeight.animator().constant = list
                consoleHeight.animator().constant = shown
                height.animator().constant = bar
            } completionHandler: {
                MainActor.assumeIsolated { GhosttyTerminalView.holdSize(false) }   // AppKit runs it on the main thread
            }
        } else {
            listHeight?.constant = list
            consoleHeight?.constant = shown
            height?.constant = bar
        }
        showHeader(Date())
    }

    /// Folded, the run going on or the last thing it ran; unfolded, a run's name or how many there are.
    private func showHeader(_ now: Date) {
        let count = String(localized: "\(items.count) commands")
        let run = current
        if let run { header.row.show(run: run, tail: tails[run.id], page: port(of: run), now: now) }
        else if unfolded || items.isEmpty { header.row.show(nil, title: count, now: now) }
        else if case .command(let last)? = items.last { header.row.show(last, now: now) }
        header.showActions(for: run, always: unfolded)
        header.chevron.image = .symbol(unfolded ? "chevron.down" : "chevron.up", unfolded ? String(localized: "Hide the commands") : count)
        header.toolTip = unfolded ? String(localized: "Hide the commands") : String(localized: "Show the commands it ran (\(items.count))")
        header.setAccessibilityLabel(header.toolTip)
    }

    /// Times move on while a command runs, and a run's last line with them.
    private func tick() {
        let running = commands.contains { $0.outcome == nil } || runs.contains { $0.status != .exited }
        if running, clock == nil, window != nil {
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.tick() }
            }
        } else if !running { clock?.invalidate(); clock = nil }
        readTails()
        let now = Date()
        showHeader(now)
        guard unfolded else { return }
        for (r, item) in items.enumerated() {
            guard let row = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? CommandRow else { continue }
            switch item {
            case .run(let s) where s.status != .exited: row.show(run: s, tail: tails[s.id], page: port(of: s), now: now)
            case .command(let c) where c.outcome == nil: row.show(c, now: now)
            default: break
            }
        }
    }

    /// The page a run serves: the port on this Mac.
    private func port(of s: Session) -> Int? {
        s.worktreeId.flatMap { app.ports[$0] }?.first { $0.session == s.id && ServedPages.listed($0) }.map { $0.here ?? $0.port }
    }

    /// The last line of what's running, on screen only; of what ended, once more for the last word.
    private func readTails() {
        let want = runs.filter { !finalTails.contains($0.id) }
        guard !reading, !want.isEmpty, window != nil else { return }
        reading = true
        Task {
            for s in want {
                guard let text = await app.quiet(SessionRead(id: s.id, bytes: 2048)) else { continue }
                tails[s.id] = Self.lastLine(text) ?? tails[s.id] ?? ""
                if s.status == .exited { finalTails.insert(s.id) }
            }
            reading = false
            showHeader(Date())
        }
    }

    /// What a program last printed: the line it's on now, past any carriage return (a progress line rewrites itself).
    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }.map { String($0.prefix(200)) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clock?.invalidate(); clock = nil } else { tick() }   // no clock for a tab out of sight
    }

    @objc private func clickedRow() { showItem(table.clickedRow) }
    private func showItem(_ row: Int) {
        guard items.indices.contains(row) else { return }
        switch items[row] {
        case .run(let s):
            open(s)
            layOut(animated: true)
        case .command(let c):
            popover.contentViewController = CommandOutput(c)
            popover.show(relativeTo: table.rect(ofRow: row), of: table, preferredEdge: .minY)
        }
    }

    /// A command's row.
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        switch items[row] {
        case .run(let s): add(run: s, to: m)
        case .command(let c):
            m.add(String(localized: "Show Output")) { [weak self] in self?.showItem(row) }
            addCopy(to: m, c.command)
        }
    }
    private func add(run s: Session, to m: NSMenu) {
        m.add(String(localized: "Open in Tab")) { [weak self] in self?.moveToTab(s) }
        if s.status != .exited { m.add(String(localized: "Stop")) { [weak self] in self?.stop(s) } }
        addCopy(to: m, s.argv.last ?? s.command)
    }
    private func addCopy(to m: NSMenu, _ command: String) {
        m.add(String(localized: "Copy Command")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
    }
    /// The bar's own line: its last command, and the way to turn the shell tool's commands off.
    private func headerMenu() -> NSMenu {
        let m = NSMenu(), app = app
        if let s = current { add(run: s, to: m) } else if let last = commands.last { addCopy(to: m, last.command) }
        if m.numberOfItems > 0 { m.addItem(.separator()) }
        if !commands.isEmpty {
            m.add(String(localized: "Hide Commands Bar")) {
                app.settings.set("agents.commandsBar", .bool(false))
                Banner.show(String(localized: "The commands bar is hidden. Settings › Agents brings it back."))
            }
        }
        m.addSettingsLink(String(localized: "Agents Settings…"), section: "agents", app)
        return m
    }

    func numberOfRows(in t: NSTableView) -> Int { items.count }
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let v = t.makeView(withIdentifier: CommandRow.id, owner: nil) as? CommandRow ?? CommandRow()
        switch items[row] {
        case .run(let s): v.show(run: s, tail: tails[s.id], page: port(of: s), now: Date())
        case .command(let command): v.show(command, now: Date())
        }
        return v
    }
}

/// The bar's own line: the last command or the count, what can be done to a run under the pointer, and a chevron. A click
/// folds or unfolds.
@MainActor
private final class Header: PointerControl {
    let row = CommandRow(), chevron = NSImageView()
    let stop = PointerButton(), toTab = PointerButton()
    var press: () -> Void = {}
    var contextMenu: (() -> NSMenu?)?
    private var run: Session?, always = false
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    init() {
        super.init(frame: .zero)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        for (b, title) in [(stop, String(localized: "Stop")), (toTab, String(localized: "Open in Tab"))] {
            b.title = title
            b.font = .ui(11)
            b.padding = Metrics.gap
            b.restFill = .fillHover
            b.isHidden = true
        }
        let s = NSStackView(views: [row, stop, toTab, chevron])
        s.spacing = Metrics.gap
        s.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: Metrics.inset)
        pin(s)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func clicked() { press() }

    func showActions(for run: Session?, always: Bool) {
        self.run = run; self.always = always
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
private final class Grip: NSView {
    var dragged: (CGFloat) -> Void = { _ in }
    private var last: CGFloat = 0
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with e: NSEvent) { GhosttyTerminalView.holdSize(true); last = e.locationInWindow.y }
    override func mouseDragged(with e: NSEvent) { dragged(e.locationInWindow.y - last); last = e.locationInWindow.y }
    override func mouseUp(with e: NSEvent) { GhosttyTerminalView.holdSize(false) }
}

/// One command: its mark, the agent's words for it, what it runs in grey, and how long it took or has been running.
@MainActor
final class CommandRow: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("command")
    private let mark = StatusMark(size: 12)
    private let server = NSImageView(image: .symbol("play.fill", String(localized: "Serving a page")))
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
        server.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        server.contentTintColor = .systemGreen
        server.isHidden = true
        for v in [server, mark] { v.translatesAutoresizingMaskIntoConstraints = false }
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(mark)
        slot.addSubview(server)
        NSLayoutConstraint.activate([slot.widthAnchor.constraint(equalToConstant: 12), slot.heightAnchor.constraint(equalToConstant: 12),
                                     mark.centerXAnchor.constraint(equalTo: slot.centerXAnchor), mark.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                                     server.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                                     server.centerYAnchor.constraint(equalTo: slot.centerYAnchor)])
        let s = NSStackView(views: [slot, lead, command, time])
        s.spacing = Metrics.gapWide
        s.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        pin(s)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A command with a terminal: its name, what it last printed, or how it ended. Green ▶ while it serves a page.
    func show(run s: Session, tail: String?, page: Int?, now: Date) {
        let live = s.status != .exited, serving = live && page != nil
        let status = live ? AgentStatus.working : Self.status(exit: s.exitCode)
        mark.status = serving ? nil : status
        server.isHidden = !serving
        slot.isHidden = false
        lead.font = .ui(11, weight: .medium)
        lead.stringValue = s.displayTitle
        command.textColor = status == .error ? .textRed : .secondaryLabelColor
        command.stringValue = serving ? "localhost:\(page ?? 0)" : live ? tail ?? "" : Self.ending(s, tail: tail)
        time.stringValue = shortSpan((live ? now : s.statusAt ?? now).timeIntervalSince(s.createdAt), units: 2, smallest: .second)
        toolTip = s.argv.last ?? s.command
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
