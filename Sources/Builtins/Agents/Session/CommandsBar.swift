import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit
import WorkbenchKit

/// The bar under an agent's terminal that lists what the agent ran. It lists the commands the agent started in
/// terminals of their own (`Session.startedBy`, `kelp session new --cmd`), and the commands its shell tool ran
/// (`AgentCommand`, reported by the agent's hooks when the setting in Settings › Agents is on). Folded, the bar is one
/// line that names the running command, or else the last one. A click unfolds the list with the current command's own
/// terminal, and a click on a shell command's row shows what it printed. The bar appears with the first command and
/// then stays, because a terminal that grew and shrank with each command would redraw the agent every time.
@MainActor
final class CommandsBar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// One row in the list: a command that has its own terminal, or a command the agent's shell tool ran.
    enum Item {
        case run(Session), command(AgentCommand)
        var started: Date {
            switch self {
            case .run(let run): run.createdAt
            case .command(let command): command.started
            }
        }
    }

    let app: AppModel
    let session: String
    private let watched: Watched
    private let header = Header()
    private let grip = Grip()
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let consoleBox = NSView()
    private var height: NSLayoutConstraint?, listHeight: NSLayoutConstraint?, consoleHeight: NSLayoutConstraint?
    var commands: [AgentCommand] = []
    private var runs: [Session] = []
    var items: [Item] = []
    /// The last line each run printed.
    private var tails: [String: String] = [:]
    private var finalTails: Set<String> = []
    private var reading = false
    private var unfolded = false
    /// The run shown in its own terminal while the bar is unfolded, and the share of the pane's height it takes.
    private var console: PaneView?
    private var share: CGFloat = 0.4
    private var escape: Any?
    /// Called when the user closes the console from the keyboard, so the keys go back to the agent.
    var onClosed: (() -> Void)?
    /// Ticks every second while a command runs, to update its time. It stops when the bar leaves the window.
    private(set) var clock: Timer?
    let popover = NSPopover()
    /// How many rows the list shows before it scrolls, on its own and when a console is open under it.
    private static let shownRows = 8, rowsOverConsole = 4
    private static var rowHeight: CGFloat { TextSize.of(Metrics.row) }

    /// `watch` is true for an agent, whose hooks and commands fill the bar. A plain terminal's bar stays empty.
    init(session: String, app: AppModel, watch: Bool) {
        self.app = app
        self.session = session
        watched = Watched(.commands, in: app)
        super.init(frame: .zero)
        let line = NSBox()
        line.boxType = .separator
        table.plainList("c", in: scroll)
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedRow)
        table.menu = NSMenu()
        table.menu?.delegate = self
        popover.behavior = .transient
        consoleBox.clipsToBounds = true
        header.onClick = { [weak self] in self?.fold(self?.unfolded == true) }
        header.contextMenu = { [weak self] in self?.headerMenu() }
        header.stop.onClick = { [weak self] in if let run = self?.current { self?.stop(run) } }
        header.toTab.onClick = { [weak self] in if let run = self?.current { self?.moveToTab(run) } }
        grip.isHidden = true
        grip.dragged = { [weak self] in self?.drag(by: $0) }
        for part in [line, header, scroll, consoleBox, grip] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        let barHeight = heightAnchor.constraint(equalToConstant: 0),
            lh = scroll.heightAnchor.constraint(equalToConstant: 0)
        let ch = consoleBox.heightAnchor.constraint(equalToConstant: 0)
        (height, listHeight, consoleHeight) = (barHeight, lh, ch)
        NSLayoutConstraint.activate([
            barHeight, lh, ch,
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.statusBar)),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            consoleBox.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            consoleBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            consoleBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            grip.topAnchor.constraint(equalTo: topAnchor), grip.heightAnchor.constraint(equalToConstant: Metrics.gap),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        isHidden = true
        guard watch else { return }
        // The setting is off by default (Settings › Agents). When it is off, the bar neither shows nor watches the
        // commands the hooks report.
        let on = { [app] in app.settings[SettingKeys.commandsBar] }
        track(owner: self) {
            on()
        } changed: { [weak self] in
            self?.watched.key = $0 ? session : nil
        }
        track(owner: self) { [app] in
            on() ? app.latest(CommandsEvent.self, session)?.commands ?? [] : nil
        } changed: { [weak self] in
            self?.show($0)
        }
        track(owner: self) { [app] in
            app.workbench.onLine(of: session)
        } changed: { [weak self] in
            self?.show(runs: $0)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the shell tool's commands. `list` is nil when the setting is switched off.
    private func show(_ list: [AgentCommand]?) {
        guard let list else {
            commands = []
            popover.close()
            reload(keeping: false)
            return
        }
        guard !list.isEmpty || !items.isEmpty else { return }   // a restarted daemon sends an empty list: keep the bar
        commands = list
        reload(keeping: true)
    }

    private func show(runs list: [Session]) {
        runs = list.sorted { $0.createdAt < $1.createdAt }
        if let console {
            if let run = app.session(console.sessionId), list.contains(where: { $0.id == run.id }) {
                console.update(run)
            } else {
                closeConsole()
            }
        }
        reload(keeping: true)
    }

    /// Rebuilds the rows. With `keeping`, an empty list leaves the bar shown, so the terminal above it doesn't move.
    private func reload(keeping: Bool) {
        let atEnd = table.rows(in: table.visibleRect).upperBound >= items.count
        items = (runs.map(Item.run) + commands.map(Item.command)).sorted { $0.started < $1.started }
        if !items.isEmpty { isHidden = false } else if !keeping { isHidden = true }
        table.reloadData()
        if atEnd, !items.isEmpty { table.scrollRowToVisible(items.count - 1) }
        layOut()
        tick()
    }

    /// The run the folded line shows: the newest run still going, or else the last item if that item is a run.
    var current: Session? {
        runs.last { $0.status != .exited } ?? { if case .run(let run)? = items.last { run } else { nil } }()
    }

    /// Unfolds or folds the list and the console. The terminal above keeps its size until the animation ends, because
    /// otherwise it would redraw the agent at every step.
    private func fold(_ fold: Bool) {
        unfolded = !fold
        if fold { popover.close() } else if let run = current { open(run) }
        // The console is removed only after the bar has closed over it, because removing it first made an empty box
        // shrink.
        layOut(animated: true) { [weak self] in
            guard let self, fold, !unfolded else { return }
            closeConsole()
        }
        header.chevron.turn(from: .pi)
        if unfolded, !items.isEmpty { table.scrollRowToVisible(items.count - 1) }
    }

    /// Shows session `s` in the console. The keyboard focus stays where it is. A click in the console takes the focus,
    /// and Esc gives it back.
    func open(_ session: Session) {
        guard console?.sessionId != session.id else { return }
        console?.removeFromSuperview()
        let pane = PaneView(session: session, app: app, embedded: true)
        console = pane
        consoleBox.pin(pane)
        grip.isHidden = false
        guard escape == nil else { return }
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, let responder = window?.firstResponder as? NSView,
                responder.isDescendant(of: consoleBox)
            else { return event }
            fold(true)
            onClosed?()
            return nil
        }
    }

    private func closeConsole() {
        console?.removeFromSuperview()
        console = nil
        grip.isHidden = true
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }

    func stop(_ session: Session) { Task { await app.call(SessionKill(id: session.id)) } }
    func moveToTab(_ session: Session) {
        if console?.sessionId == session.id { fold(true) }
        app.workbench.openInTab(session.id)
        show(runs: runs.filter { $0.id != session.id })
        if items.isEmpty { reload(keeping: false) }
    }

    /// Called when the pane changes height, so the console keeps its share of it.
    func paneResized() { if console != nil { layOut() } }

    private func drag(by dy: CGFloat) {
        guard let pane = superview?.bounds.height, pane > 0, let now = consoleHeight?.constant else { return }
        share = min(0.8, max(0.15, (now + dy) / pane))
        layOut()
    }

    func layOut(animated: Bool = false, then: (@MainActor () -> Void)? = nil) {
        var list: CGFloat = 0, shown: CGFloat = 0
        if unfolded {
            let rows =
                console == nil
                ? min(items.count, Self.shownRows) : items.count > 1 ? min(items.count, Self.rowsOverConsole) : 0
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
                MainActor.assumeIsolated {   // AppKit runs it on the main thread
                    GhosttyTerminalView.holdSize(false)
                    then?()
                }
            }
        } else {
            listHeight?.constant = list
            consoleHeight?.constant = shown
            height?.constant = bar
            then?()
        }
        showHeader(Date())
    }

    /// Updates the header line. It shows the current run when there is one. Otherwise it shows the last shell command
    /// when folded, and how many commands there are when unfolded.
    private func showHeader(_ now: Date) {
        let count = String(localized: "\(items.count) commands")
        let run = current
        if let run {
            header.row.show(run: run, tail: tails[run.id], page: port(of: run), now: now)
        } else if unfolded || items.isEmpty {
            header.row.show(nil, title: count, now: now)
        } else if case .command(let last)? = items.last {
            header.row.show(last, now: now)
        }
        header.showActions(for: run, always: unfolded)
        header.chevron.image = .symbol(
            unfolded ? "chevron.down" : "chevron.up", unfolded ? String(localized: "Hide the commands") : count)
        header.toolTip =
            unfolded
            ? String(localized: "Hide the commands") : String(localized: "Show the commands it ran (\(items.count))")
        header.setAccessibilityLabel(header.toolTip)
    }

    /// Updates the times while a command runs, and the last line of each run along with them.
    private func tick() {
        let running = commands.contains { $0.outcome == nil } || runs.contains { $0.status != .exited }
        if running, clock == nil, window != nil {
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.tick() }
            }
        } else if !running {
            clock?.invalidate()
            clock = nil
        }
        // When the bar is out of sight (another window covers it, or Kelp is hidden), it doesn't read the commands'
        // last lines and redraws nothing. The clock keeps ticking for when the bar is back in view.
        guard window?.occlusionState.contains(.visible) == true else { return }
        readTails()
        let now = Date()
        showHeader(now)
        guard unfolded else { return }
        for (index, item) in items.enumerated() {
            guard let row = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? CommandRow else { continue }
            switch item {
            case .run(let run) where run.status != .exited:
                row.show(run: run, tail: tails[run.id], page: port(of: run), now: now)
            case .command(let command) where command.outcome == nil: row.show(command, now: now)
            default: break
            }
        }
    }

    /// Returns the port on this Mac of the page a run serves, if it serves one.
    private func port(of run: Session) -> Int? {
        run.worktreeId.flatMap { app.latest(PortsEvent.self, $0)?.ports }?.first {
            $0.session == run.id && ServedPages.listed($0)
        }.map { $0.here ?? $0.port }
    }

    /// Reads the last line of each run while the bar is in a window. A run that has ended is read once more, to get
    /// its final line.
    private func readTails() {
        let want = runs.filter { !finalTails.contains($0.id) }
        guard !reading, !want.isEmpty, window != nil else { return }
        reading = true
        Task {
            for run in want {
                guard let text = await app.quiet(SessionRead(id: run.id, bytes: 2048)) else { continue }
                tails[run.id] = Self.lastLine(text) ?? tails[run.id] ?? ""
                if run.status == .exited { finalTails.insert(run.id) }
            }
            reading = false
            showHeader(Date())
        }
    }

    /// Returns the last non-empty line a program printed, cut to 200 characters. A carriage return also ends a line,
    /// because a progress line rewrites itself after one.
    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }.map { String($0.prefix(200)) }
    }

    isolated deinit { clock?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clock?.invalidate()
            clock = nil
        } else {
            tick()
        }   // no clock for a tab out of sight
    }

    func numberOfRows(in table: NSTableView) -> Int { items.count }
    func tableView(_ table: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ table: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let cell = table.makeView(withIdentifier: CommandRow.id, owner: nil) as? CommandRow ?? CommandRow()
        switch items[row] {
        case .run(let run): cell.show(run: run, tail: tails[run.id], page: port(of: run), now: Date())
        case .command(let command): cell.show(command, now: Date())
        }
        return cell
    }
}
