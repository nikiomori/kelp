import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit
import WorkbenchKit

/// One terminal bound to one daemon session, rendered by libghostty. The terminal runs `kelp attach`, so the daemon
/// keeps the process.
@MainActor
final class PaneView: NSView {
    let sessionId: String
    let app: AppModel
    /// The terminal view. It is nil after the pane lets go of its attach (`letGo`), until the pane is shown again.
    var ghostty: GhosttyTerminalView?
    private let endedLabel = NSTextField(labelWithString: String(localized: "Session ended"))
    private let restartButton = NSButton()
    /// The bar that says the session stopped and offers what to do about it. It sits under the output, so it covers
    /// none of it, and it has no height while the session runs.
    private lazy var endedBar = Bar.foot([endedLabel], [restartButton, closeButton])
    private lazy var closeButton = NSButton(
        title: String(localized: "Close"), target: self, action: #selector(closeTapped))
    private let endedSlot = NSView()
    private(set) lazy var endedHeight = endedSlot.heightAnchor.constraint(equalToConstant: 0)
    private var endedLeaving = false
    /// The bar under the terminal that lists the commands an agent ran.
    private let commands: CommandsBar
    /// The strip over the bottom of the terminal, made the first time a plan limit stops this agent.
    private var limitStrip: NSView?
    /// The card that also sits over the bottom of the terminal, made the first time this agent asks to change a
    /// database (`DatabaseAskCard`).
    private var askCard: DatabaseAskCard?
    /// The card in the same place for the user's login on a site (`LoginAskCard`).
    private var loginCard: LoginAskCard?
    /// Whether `kelp attach` still streams, and which daemon it streams from (the value of `AppModel.connections` when
    /// it started).
    private var attached = true
    private var attachedTo: Int
    /// The status seen last. When a session goes from running to paused, the daemon ends `kelp attach` for all of its
    /// terminals, this one included.
    /// Limit: a pause and a wake handled in one run-loop turn look like no change; a per-session pause count would see it.
    private var lastStatus: AgentStatus?
    /// True when the pane is the console in the commands bar under an agent's terminal. That bar says itself how the
    /// command ended, so the pane shows no ended bar and offers no splits.
    private let embedded: Bool

    var onClose: ((PaneView) -> Void)?
    var onRestart: ((PaneView) -> Void)?

    init(session: Session, app: AppModel, embedded: Bool = false) {
        sessionId = session.id
        self.app = app
        self.embedded = embedded
        // An agent Kelp's going down cut short shows what it printed last, not woken, and attaches once it goes on.
        attachedTo = session.interrupted ? -1 : app.connections
        commands = CommandsBar(session: session.id, app: app, watch: session.isAgent)
        super.init(frame: .zero)
        wantsLayer = true
        commands.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commands)
        NSLayoutConstraint.activate([
            commands.leadingAnchor.constraint(equalTo: leadingAnchor),
            commands.trailingAnchor.constraint(equalTo: trailingAnchor),
            commands.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        buildEndedBar()
        attached = !session.interrupted
        buildTerminal(session, session.interrupted ? Self.replay(session) : nil)
        commands.onClosed = { [weak self] in self?.focus() }
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        update(session)
        track(owner: self) { [app] in
            app.connections
        } changed: { [weak self] _ in
            self?.settle()
        }
        if let wid = session.worktreeId {   // an agent started by typing in a terminal asks there too
            let sid = session.id
            track(owner: self) { [app] in
                app.session(sid)?.asksPermission == true
            } changed: { [weak self] asks in
                if asks { self?.showAskCard(worktree: wid) }
            }
        }
    }

    private func showAskCard(worktree: String) {
        guard askCard == nil else { return }
        let card = DatabaseAskCard(app: app, session: sessionId, worktree: worktree)   // it shows and hides itself
        askCard = card
        overlay(card)
        let login = LoginAskCard(app: app, session: sessionId)   // so does this one, for another question
        loginCard = login
        overlay(login)
    }

    /// Places a card over the bottom of the terminal, inset from its edges, above the ended bar.
    private func overlay(_ card: NSView) {
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gapWide * 1.5),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.gapWide * 1.5),
            card.bottomAnchor.constraint(equalTo: endedSlot.topAnchor, constant: -Metrics.gapWide * 1.5)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private lazy var preview = PathPreview(app: app)
    private lazy var linkPill = LinkPill(in: self, above: endedSlot)

    private static func terminal(_ session: Session) -> GhosttyTerminalView {
        let kelp = Bundle.main.bundleURL.appendingPathComponent(
            Bundle.main.bundleIdentifier == nil ? "kelp" : "Contents/MacOS/kelp"
        ).path
        return GhosttyTerminalView(
            command: ShellQuote.word(kelp) + " attach \(session.id)", cwd: session.cwd,
            env: ["KELP_SOCKET": Paths.socket.path, "KELP_HOME": Paths.root.path])
    }

    private func buildTerminal(_ session: Session, _ shown: GhosttyTerminalView? = nil) {
        let id = session.id, terminal = shown ?? Self.terminal(session)
        ghostty = terminal
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: endedSlot.topAnchor)
        ])
        terminal.onExit = { [weak self] in
            self?.attached = false
            self?.settle()
        }
        terminal.onSearch = { [weak self] in self?.searchEvent($0) }
        // Paths the agent prints are relative to its folder, which is its own worktree once it has moved into one.
        let cwd = { [app] in app.session(id)?.currentDir ?? session.cwd }, wid = session.worktreeId
        let projects = { [app] in app.repos.map(\.path) }, app = app
        terminal.onOpenURL = { Self.openLink($0, cwd: cwd(), elsewhere: projects(), workspace: wid, in: app) }
        terminal.onPasteRefused = {
            Banner.show(
                String(
                    localized:
                        "Not pasted: a program put these lines on the clipboard, and this terminal would run them as typed. Copy them yourself to paste here."
                ))
        }
        terminal.onOpenPath = { token, flags in
            TerminalPaths.open(token, cwd: cwd(), elsewhere: projects(), workspace: wid, flags: flags, in: app)
        }
        terminal.onPathAt = { tokens in
            let dir = cwd(), roots = projects()
            // The lookup stats files in every project: off the main thread, so a slow volume doesn't stall the window.
            return await Task.detached { TerminalPaths.shown(tokens, cwd: dir, elsewhere: roots) }.value
        }
        terminal.onLinkHover = { [weak self] in self?.linkPill.show($0) }
        terminal.onHoverWord = { [weak self, weak terminal] tokens, rect in
            guard let self, let terminal else { return }
            self.preview.show(tokens, rect: rect, in: terminal, cwd: cwd(), worktree: wid)
        }
    }

    private func buildEndedBar() {
        endedLabel.font = .ui(TextSize.row)   // 500 is for what is selected
        restartButton.title = String(localized: "Restart")
        restartButton.target = self
        restartButton.action = #selector(restartTapped)
        for button in [restartButton, closeButton] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        endedSlot.clipsToBounds = true
        for v in [endedSlot, endedBar] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(endedSlot)
        endedSlot.addSubview(endedBar)
        NSLayoutConstraint.activate([
            endedHeight, endedSlot.bottomAnchor.constraint(equalTo: commands.topAnchor),
            endedSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            endedSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            endedBar.topAnchor.constraint(equalTo: endedSlot.topAnchor),
            endedBar.leadingAnchor.constraint(equalTo: endedSlot.leadingAnchor),
            endedBar.trailingAnchor.constraint(equalTo: endedSlot.trailingAnchor)
        ])
    }

    /// Brings the pane in line with its session and connection. A new connection may mean a new daemon (after an
    /// update, Restart Background Service or a crash), and this stream no longer reaches the session there. libghostty
    /// reports that `kelp attach` exited only after a key press, so the new connection is the sign to act on. A pause
    /// is a sign too, because the daemon hangs up the terminals of a session it pauses (when its workspace is archived
    /// or closed). If the session lives on, the pane attaches again, but only on screen. A hidden tab attaches when it
    /// is shown, so a restart doesn't wake every paused agent. A paused session attaches again when it is next shown
    /// (which wakes it, as opening any paused tab does) or on Resume, and never on screen right after its pause.
    /// Against the same daemon, attaching again is one history replay and loses nothing. When the session has ended,
    /// the pane says "Session ended".
    private func settle(shown: Bool = false) {
        let session = app.session(sessionId), model = app
        if session?.status == .paused, let was = lastStatus, was != .paused { attached = false }
        lastStatus = session?.status
        let cutShort = session?.interrupted == true   // it waits for Continue: the stream from a daemon gone is over
        if cutShort, model.connections != attachedTo { attached = false }
        // A session whose connection to its host dropped (after a sleep or a network change) attaches again when it
        // is shown, as a paused one does. It attaches to its agent, which still runs in tmux on the host under the
        // same session.
        if let session, !cutShort, session.status != .exited || session.connectionLost && shown, model.connected,
            window != nil,
            model.connections != attachedTo || shown && !attached
        {
            reattach(session)
        }
        let paused = !attached && session?.status == .paused
        // A pane let go of while hidden has not stopped. Otherwise the ended bar would greet the tab when it is shown
        // again, and then fade.
        let stopped = !embedded && (!attached && !released || session?.status == .exited)
        if stopped, endedLeaving {   // stopped again while the bar was fading out
            endedLeaving = false
            endedBar.animator().alphaValue = 1
        }
        if stopped != (endedHeight.constant > 0), !endedLeaving {
            if stopped {
                endedHeight.constant = endedBar.fittingSize.height
                endedBar.comeIn()
            } else if window == nil || Motion.reduced {
                endedHeight.constant = 0
            } else {
                // The bar fades out the way it came in, and the terminal takes its room only once it's gone, so the
                // bar isn't cut off in a single frame.
                endedLeaving = true
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.slow
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    endedBar.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {   // AppKit runs it on the main thread
                        guard let self, self.endedLeaving else { return }
                        self.endedLeaving = false
                        self.endedHeight.constant = 0
                        self.endedBar.alphaValue = 1
                    }
                }
            }
        }
        // When the connection is lost (Session.connectionLost), the agent still runs in tmux on the host, and
        // Reconnect attaches to it again.
        let lost = session?.connectionLost == true
        endedLabel.stringValue =
            paused
            ? Self.pausedWords(session)
            : lost ? String(localized: "Connection lost") : String(localized: "Session ended")
        restartButton.title =
            paused ? Self.pausedButton(session) : lost ? String(localized: "Reconnect") : String(localized: "Restart")
    }

    private func reattach(_ session: Session) {
        let focused = ghostty.map { window?.firstResponder === $0 } ?? false
        findBar?.removeFromSuperview()
        findBar = nil   // the find bar searched the old terminal
        ghostty?.removeFromSuperview()
        attached = true
        released = false
        attachedTo = app.connections
        buildTerminal(session)
        if focused { focus() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        settle(shown: true)
        offScreen?.cancel()
        offScreen = nil
        guard window == nil else { return }
        let wait = Self.offScreenWait(hibernateMinutes: app.settings[SettingKeys.hibernateMinutes])
        offScreen = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { self?.letGo() }
        }
    }

    private(set) var offScreen: Task<Void, Never>?

    /// How long a terminal out of sight keeps its surface. Each surface takes about 50 MB of GPU memory, so a few
    /// hidden tabs add up.
    static let releaseAfter: TimeInterval = 5 * 60
    /// Returns how long a hidden terminal waits before it lets go: `releaseAfter`, or less when idle agents pause
    /// sooner. It must not wait longer, because the daemon pauses only an agent that nobody is attached to.
    static func offScreenWait(hibernateMinutes: Double) -> TimeInterval {
        hibernateMinutes > 0 ? min(releaseAfter, hibernateMinutes * 60) : releaseAfter
    }

    /// True after the pane let go of its terminal while out of sight (`letGo`). The session hasn't stopped, it is only
    /// not drawn, and the pane attaches anew when it is shown again.
    private(set) var released = false

    /// Called once the pane has been out of sight for a while (`offScreenWait`). It removes the terminal, and `kelp
    /// attach` with it, while the session runs on in the daemon. Letting go pauses nothing, but with nobody attached,
    /// the daemon's Pause idle agents setting may pause an idle agent. A tab in any window (a group's own window too,
    /// minimised or not) is never let go of. When the pane is shown again, it attaches anew (`settle`), which is one
    /// history replay, or a wake if its agent was paused meanwhile.
    func letGo() {
        guard window == nil, attached else { return }
        findBar?.removeFromSuperview()
        findBar = nil
        ghostty?.removeFromSuperview()
        ghostty = nil
        attached = false
        released = true
    }

    func update(_ session: Session) {
        settle()
        guard limitStrip == nil, session.limitHit != nil else { return }
        let strip = LimitStrip(app: app, session: session.id)   // it shows and hides itself
        limitStrip = strip
        overlay(strip)
    }

    func focus() { ghostty?.focus() }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.height != frame.height
        super.setFrameSize(newSize)
        if changed { commands.paneResized() }
    }

    /// The terminal's columns × rows right now. Each read also stores the grid in `app.workbench.terminalGrid`, because
    /// the last grid seen anywhere sizes the next terminal before it is on screen.
    var gridSize: (cols: Int, rows: Int)? {
        if let grid = ghostty?.gridSize {
            app.workbench.terminalGrid = grid
            return grid
        }
        return nil
    }

    /// Inserts text dropped or dictated into the prompt.
    func insert(_ text: String) { ghostty?.insert(text) }

    /// The right-click menu, like Terminal's, shown where the program in the terminal doesn't take the mouse itself.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let terminal = ghostty else { return nil }
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(localized: "Copy"), action: #selector(GhosttyTerminalView.copy(_:)), keyEquivalent: ""
        ).target = terminal
        menu.items.last?.isEnabled = terminal.hasSelection
        menu.autoenablesItems = false
        menu.addItem(
            withTitle: String(localized: "Paste"), action: #selector(GhosttyTerminalView.paste(_:)), keyEquivalent: ""
        ).target = terminal
        menu.addItem(
            withTitle: String(localized: "Select All"), action: #selector(GhosttyTerminalView.selectAll(_:)),
            keyEquivalent: ""
        ).target = terminal
        menu.addItem(.separator())
        let shell = app.session(sessionId)?.isTerminal == true
        addSend(to: menu, selection: terminal.selection)
        menu.add(String(localized: "Find…")) { [weak self] in self?.showFind(nil) }
        if shell { menu.add(String(localized: "Clear")) { _ = terminal.perform(action: "clear_screen") } }
        if embedded { return menu }
        menu.addItem(.separator())
        menu.add(String(localized: "New Terminal to the Right")) { [weak self] in
            self?.focus()
            self?.app.workbench.splitTerminal(.right)
        }
        menu.add(String(localized: "New Terminal Below")) { [weak self] in
            self?.focus()
            self?.app.workbench.splitTerminal(.down)
        }
        return menu
    }

    @objc private func closeTapped() { onClose?(self) }
    /// On a paused pane the button is Resume, and on a pane whose host dropped it is Reconnect. Both attach again,
    /// which wakes the agent. Otherwise the button is Restart, and the session starts over.
    @objc private func restartTapped() {
        if !attached, Self.continueCutShort(app.session(sessionId), app) { return }   // attached once it goes on
        if !attached, let session = app.session(sessionId), session.status == .paused || session.connectionLost {
            reattach(session)
            settle()
        } else {
            onRestart?(self)
        }
    }

    var findBar: FindCard?

    /// Where a dragged file will land, as on an editor pane; made at the first drag (`PaneView+Drops.swift`).
    lazy var dropHint = DropHint()
}
