import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit
import WorkbenchKit

/// One terminal bound to one daemon session, rendered by libghostty (attached via `kelp attach`, so the daemon keeps
/// the process).
@MainActor
final class PaneView: NSView {
    let sessionId: String
    let app: AppModel
    /// None once it let go of its attach (`letGo`), until it's shown again.
    private var ghostty: GhosttyTerminalView?
    private let endedLabel = NSTextField(labelWithString: String(localized: "Session ended"))
    private let restartButton = NSButton()
    /// Under the output, which it must not cover: that the session stopped, and what to do about it. No height while it runs.
    private lazy var endedBar = Bar.foot([endedLabel], [restartButton, closeButton])
    private lazy var closeButton = NSButton(
        title: String(localized: "Close"), target: self, action: #selector(closeTapped))
    private let endedSlot = NSView()
    private lazy var endedHeight = endedSlot.heightAnchor.constraint(equalToConstant: 0)
    /// Under the terminal: what an agent's shell tool ran.
    private let commands: CommandsBar
    /// Over the terminal's foot, made the first time a plan limit stops this agent.
    private var limitStrip: NSView?
    /// `kelp attach` still streams, and from which daemon (`AppModel.connections` when it started).
    private var attached = true
    private var attachedTo: Int
    /// The status last seen: a session that goes from running to paused had its terminals hung up (the daemon ends
    /// `kelp attach` then), this one's included.
    /// Limit: a pause and a wake handled in one run-loop turn look like no change; a per-session pause count would see it.
    private var lastStatus: AgentStatus?
    /// In the line under an agent's terminal, which says itself how the command ended: no bar for that, no splits.
    private let embedded: Bool

    var onClose: ((PaneView) -> Void)?
    var onRestart: ((PaneView) -> Void)?

    init(session: Session, app: AppModel, embedded: Bool = false) {
        sessionId = session.id
        self.app = app
        self.embedded = embedded
        attachedTo = app.connections
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
        buildTerminal(session)
        commands.onClosed = { [weak self] in self?.focus() }
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        update(session)
        track(owner: self) { [app] in
            app.connections
        } changed: { [weak self] _ in
            self?.settle()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private lazy var preview = PathPreview(app: app)

    private static func terminal(_ s: Session) -> GhosttyTerminalView {
        let kelp = Bundle.main.bundleURL.appendingPathComponent(
            Bundle.main.bundleIdentifier == nil ? "kelp" : "Contents/MacOS/kelp"
        ).path
        return GhosttyTerminalView(
            command: IDE.shellWord(kelp) + " attach \(s.id)", cwd: s.cwd,
            env: ["KELP_SOCKET": Paths.socket.path, "KELP_HOME": Paths.root.path])
    }

    private func buildTerminal(_ s: Session) {
        let id = s.id, terminal = Self.terminal(s)
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
        // Paths the agent prints are its folder's: its own worktree once it went into one.
        let cwd = { [app] in app.session(id)?.currentDir ?? s.cwd }, wid = s.worktreeId
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
            TerminalPaths.open(token, cwd: cwd(), elsewhere: projects(), flags: flags, in: app)
        }
        terminal.onHoverWord = { [weak self, weak terminal] tokens, rect in
            guard let self, let terminal else { return }
            self.preview.show(tokens, rect: rect, in: terminal, cwd: cwd(), worktree: wid)
        }
    }

    private func buildEndedBar() {
        endedLabel.font = .ui(12, weight: .semibold)
        restartButton.title = String(localized: "Restart")
        restartButton.target = self
        restartButton.action = #selector(restartTapped)
        for b in [restartButton, closeButton] {
            b.bezelStyle = .push
            b.controlSize = .small
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

    /// A new connection may be a new daemon (an update, Restart Background Service, a crash), whose session this stream
    /// no longer reaches — libghostty reports the attach's exit only after a key press, so the connection is the sign.
    /// So is a pause: the daemon hangs up the terminals of a session it pauses (its workspace archived or closed).
    /// The session living on, attach again: only on screen, a hidden tab attaches when shown (a restart mustn't wake
    /// every paused agent). A paused one attaches again when it's shown next (which wakes it, as opening any paused tab
    /// does) or on Resume, never on screen right after its pause. Against the same daemon that's one history replay,
    /// nothing lost. Ended: "Session ended".
    private func settle(shown: Bool = false) {
        let session = app.session(sessionId), model = app
        if session?.status == .paused, let was = lastStatus, was != .paused { attached = false }
        lastStatus = session?.status
        if let session, session.status != .exited, model.connected, window != nil,
            model.connections != attachedTo || shown && !attached
        {
            reattach(session)
        }
        let paused = !attached && session?.status == .paused
        let stopped = !embedded && (!attached || session?.status == .exited)
        if stopped != (endedHeight.constant > 0) {
            endedHeight.constant = stopped ? endedBar.fittingSize.height : 0
            if stopped { endedBar.comeIn() }
        }
        // Its agent still runs in tmux on the host (Session.connectionLost): Reconnect attaches to it again.
        let lost = session?.connectionLost == true
        endedLabel.stringValue =
            paused
            ? String(localized: "Paused")
            : lost ? String(localized: "Connection lost") : String(localized: "Session ended")
        restartButton.title =
            paused ? String(localized: "Resume") : lost ? String(localized: "Reconnect") : String(localized: "Restart")
    }

    private func reattach(_ s: Session) {
        let focused = ghostty.map { window?.firstResponder === $0 } ?? false
        findBar?.removeFromSuperview()
        findBar = nil   // it searched the old terminal
        ghostty?.removeFromSuperview()
        attached = true
        attachedTo = app.connections
        buildTerminal(s)
        if focused { focus() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        settle(shown: true)
        offScreen?.cancel()
        offScreen = nil
        let minutes = app.settings[SettingKeys.hibernateMinutes]
        guard window == nil, minutes > 0 else { return }
        offScreen = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            if !Task.isCancelled { self?.letGo() }
        }
    }

    private var offScreen: Task<Void, Never>?

    /// Out of sight as long as an idle agent takes to pause: its terminal goes, and `kelp attach` with it. An attached
    /// session counts as watched and never pauses, and a tab once shown stays built while it's in the layout. Shown
    /// again, it attaches anew (`settle`): one history replay, or a wake if its agent was paused meanwhile.
    private func letGo() {
        guard window == nil, attached else { return }
        findBar?.removeFromSuperview()
        findBar = nil
        ghostty?.removeFromSuperview()
        ghostty = nil
        attached = false
    }

    /// A link ⌘-clicked in the terminal: local pages open as a browser tab, the rest in the default browser; ⌥ swaps
    /// the two. Files open as a tab, ⌥ or not. Nothing else opens: a program prints these links (OSC 8 hides the target
    /// behind any text), and an app, a .command file or another app's scheme would run. A link without a scheme is a
    /// path from `cwd` (or another project's, `TerminalPaths.resolve`): one Ghostty found in the text ("banner/x.html"),
    /// or an agent's Markdown link to its own file.
    /// A local link in a terminal of a remote project means the host: `url` with the port it has on this Mac. As it was
    /// on this Mac's own projects, nil when it can't be brought here.
    private static func hostLink(_ url: String, in wid: String?, _ app: AppModel) async -> String? {
        guard let wid, app.worktree(wid).flatMap({ RemoteHost.of($0.path) }) != nil,
            var components = URLComponents(string: url)
        else { return url }
        guard let forward = await app.call(PortsForward(worktreeId: wid, port: components.port ?? 80)) else {
            return nil
        }
        components.port = forward.port
        return components.string
    }

    static func openLink(_ url: URL, cwd: String, elsewhere: [String], workspace wid: String? = nil, in app: AppModel) {
        if url.scheme == nil {
            let path = url.path(percentEncoded: false)
            if !TerminalPaths.open(path, cwd: cwd, elsewhere: elsewhere, flags: NSEvent.modifierFlags, in: app) {
                Banner.show(
                    String(
                        localized:
                            "No file “\(path)” in \((cwd as NSString).abbreviatingWithTildeInPath) or your other projects."
                    ))
            }
            return
        }
        let option = NSEvent.modifierFlags.contains(.option)
        switch PreviewLinks.target(url) {
        case .web(let link):
            let local = url.host == "localhost" || url.host == "127.0.0.1"
            guard local else {
                if option { app.workbench.open(link, split: .right) } else { PreviewLinks.openOutside(url) }
                return
            }
            Task {
                guard let here = await hostLink(link, in: wid, app) else { return }
                if option {
                    URL(string: here).map(PreviewLinks.openOutside)
                } else {
                    app.workbench.open(here, split: .right)
                }
            }
        case .file(let path): app.workbench.open(TabURI.file(path), split: .right)
        case .mail, .refused: PreviewLinks.openOutside(url)   // which says why another app's scheme doesn't open
        }
    }

    func update(_ s: Session) {
        settle()
        guard limitStrip == nil, s.limitHit != nil else { return }
        let strip = LimitStrip(app: app, session: s.id)   // it shows and hides itself
        limitStrip = strip
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gapWide * 1.5),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.gapWide * 1.5),
            strip.bottomAnchor.constraint(equalTo: endedSlot.topAnchor, constant: -Metrics.gapWide * 1.5)
        ])
    }

    func focus() { ghostty?.focus() }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.height != frame.height
        super.setFrameSize(newSize)
        if changed { commands.paneResized() }
    }

    /// Columns × rows now; the last one seen anywhere (`app.workbench.terminalGrid`) sizes the next terminal before it's on screen.
    var gridSize: (cols: Int, rows: Int)? {
        if let grid = ghostty?.gridSize {
            app.workbench.terminalGrid = grid
            return grid
        }
        return nil
    }

    /// What's on screen (tests, "copy context" fallback).
    var visibleText: String { ghostty?.visibleText ?? "" }

    /// Text dropped or dictated into the prompt.
    func insert(_ text: String) { ghostty?.insert(text) }

    /// Right-click where the program in the terminal doesn't take the mouse itself, like Terminal's menu.
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
        let shell = app.session(sessionId)?.agent == "shell"
        if shell, let text = terminal.selection, !text.isEmpty {   // a build's error, handed over without copying it
            menu.add(String(localized: "Send Selection to Agent")) { [app] in FileActions(app).sendToAgent(text: text) }
        }
        menu.add(String(localized: "Find…")) { [weak self] in self?.showFind(nil) }
        if shell { menu.add(String(localized: "Clear")) { _ = terminal.perform(action: "clear_screen") } }
        if embedded { return menu }
        menu.addItem(.separator())
        menu.add(String(localized: "Split Right")) { [weak self] in
            self?.focus()
            self?.app.workbench.editor?.splitFocused(.right)
        }
        menu.add(String(localized: "Split Down")) { [weak self] in
            self?.focus()
            self?.app.workbench.editor?.splitFocused(.down)
        }
        return menu
    }

    // MARK: find (Edit › Find reaches the pane through the responder chain)
    private var findBar: FindCard?

    @objc func performFindPanelAction(_ sender: Any?) {
        guard let terminal = ghostty else { return }
        switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
        case .next?: terminal.perform(action: "navigate_search:next")
        case .previous?: terminal.perform(action: "navigate_search:previous")
        // Ghostty answers with start_search and the text
        case .setFindString?: terminal.perform(action: "search_selection")
        default: showFind(nil)
        }
    }

    private func showFind(_ needle: String?) {
        guard let terminal = ghostty else { return }
        let bar =
            findBar
            ?? {
                let card = FindCard()
                card.onSearch = { terminal.perform(action: "search:" + $0) }
                card.onStep = { terminal.perform(action: "navigate_search:" + ($0 ? "next" : "previous")) }
                card.onClose = { [weak self] in
                    terminal.perform(action: "end_search")
                    self?.focus()
                }
                card.translatesAutoresizingMaskIntoConstraints = false
                addSubview(card)
                NSLayoutConstraint.activate([
                    card.topAnchor.constraint(equalTo: terminal.topAnchor, constant: 8),
                    card.trailingAnchor.constraint(equalTo: terminal.trailingAnchor, constant: -14)
                ])
                findBar = card
                return card
            }()
        bar.begin(needle)
    }

    private func searchEvent(_ event: GhosttyTerminalView.SearchEvent) {
        switch event {
        case .started(let needle): showFind(needle)
        case .ended: findBar?.isHidden = true
        case .total(let count): findBar?.total = count
        case .selected(let count): findBar?.selected = count
        }
    }

    @objc private func closeTapped() { onClose?(self) }
    /// Resume on a paused pane attaches again (and so wakes the agent); otherwise the session starts over.
    @objc private func restartTapped() {
        if !attached, let session = app.session(sessionId), session.status == .paused {
            reattach(session)
            settle()
        } else {
            onRestart?(self)
        }
    }

    // MARK: drops: files/images/text into the agent's prompt
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var paths = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path) ?? []
        if paths.isEmpty, let png = TerminalPaste.savedImage(pb) { paths = [png] }
        if paths.isEmpty, let text = pb.string(forType: .string) {
            insert(text)
            return true
        }
        guard !paths.isEmpty else { return false }
        insert(TerminalPaste.paths(paths))
        focus()
        return true
    }
}
