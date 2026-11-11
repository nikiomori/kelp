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
    /// The run shown unfolded, in a terminal of its own, and how much of the pane it takes.
    private var console: PaneView?
    private var share: CGFloat = 0.4
    private var escape: Any?
    /// The console closed from the keyboard: the keys go back to the agent.
    var onClosed: (() -> Void)?
    /// Ticks while one runs, for its time.
    private var clock: Timer?
    let popover = NSPopover()
    /// Rows the list shows before it scrolls, alone and over a console.
    private static let shownRows = 8, rowsOverConsole = 4
    private static var rowHeight: CGFloat { TextSize.of(Metrics.row) }

    /// `watch`: an agent, whose hooks and commands fill it; a terminal's bar stays empty.
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
        for v in [line, header, scroll, consoleBox, grip] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
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
        // Off by default (Settings › Agents): off, it neither shows nor watches the hooks' commands.
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
            let inTabs = app.uiState.strings(Session.inTabKey)
            return app.sessions.filter {
                $0.startedBy == session && !inTabs.contains($0.id) && app.sessions.owner(of: $0) != nil
            }
        } changed: { [weak self] in
            self?.show(runs: $0)
        }
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
        if let console {
            if let run = app.session(console.sessionId), list.contains(where: { $0.id == run.id }) {
                console.update(run)
            } else {
                closeConsole()
            }
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
    var current: Session? {
        runs.last { $0.status != .exited } ?? { if case .run(let run)? = items.last { run } else { nil } }()
    }

    /// Unfolds or folds the list and the console; the terminal over it keeps its size until they stop, or it would redraw
    /// the agent at every step.
    private func fold(_ fold: Bool) {
        unfolded = !fold
        if fold { popover.close() } else if let run = current { open(run) }
        // The console goes once the bar has closed over it: taken out first, an empty box shrank.
        layOut(animated: true) { [weak self] in
            guard let self, fold, !unfolded else { return }
            closeConsole()
        }
        header.chevron.turn(from: .pi)
        if unfolded, !items.isEmpty { table.scrollRowToVisible(items.count - 1) }
    }

    /// `s` in the console. The keys stay where they are; a click in it takes them, Esc gives them back.
    func open(_ s: Session) {
        guard console?.sessionId != s.id else { return }
        console?.removeFromSuperview()
        let pane = PaneView(session: s, app: app, embedded: true)
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

    func stop(_ s: Session) { Task { await app.call(SessionKill(id: s.id)) } }
    func moveToTab(_ s: Session) {
        if console?.sessionId == s.id { fold(true) }
        app.workbench.openInTab(s.id)
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

    /// Folded, the run going on or the last thing it ran; unfolded, a run's name or how many there are.
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

    /// Times move on while a command runs, and a run's last line with them.
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
        // Out of sight (another window over it, Kelp hidden): no tails asked, nothing redrawn; the clock goes on for when it's back.
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

    /// The page a run serves: the port on this Mac.
    private func port(of run: Session) -> Int? {
        run.worktreeId.flatMap { app.latest(PortsEvent.self, $0)?.ports }?.first {
            $0.session == run.id && ServedPages.listed($0)
        }.map { $0.here ?? $0.port }
    }

    /// The last line of what's running, on screen only; of what ended, once more for the last word.
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

    /// What a program last printed: the line it's on now, past any carriage return (a progress line rewrites itself).
    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }.map { String($0.prefix(200)) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clock?.invalidate()
            clock = nil
        } else {
            tick()
        }   // no clock for a tab out of sight
    }

    func numberOfRows(in t: NSTableView) -> Int { items.count }
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let cell = t.makeView(withIdentifier: CommandRow.id, owner: nil) as? CommandRow ?? CommandRow()
        switch items[row] {
        case .run(let run): cell.show(run: run, tail: tails[run.id], page: port(of: run), now: Date())
        case .command(let command): cell.show(command, now: Date())
        }
        return cell
    }
}
