import AppKit
import Core
import TerminalKit
import WorkbenchKit
import KelpKit

/// One terminal bound to one daemon session, rendered by libghostty (attached via `kelp attach`, so the daemon keeps
/// the process).
@MainActor
final class PaneView: NSView {
    let sessionId: String
    let app: AppModel
    /// None once it let go of its attach (`letGo`), until it's shown again.
    private var ghostty: GhosttyTerminalView?
    private let ended = NSStackView()
    private let endedLabel = NSTextField(labelWithString: String(localized: "Session ended"))
    private let restartButton = NSButton()
    /// `kelp attach` still streams, and from which daemon (`AppModel.connections` when it started).
    private var attached = true
    private var attachedTo: Int
    /// The status last seen: a session that goes from running to paused had its terminals hung up (the daemon ends
    /// `kelp attach` then), this one's included.
    /// Limit: a pause and a wake handled in one run-loop turn look like no change; a per-session pause count would see it.
    private var lastStatus: AgentStatus?

    var onClose: ((PaneView) -> Void)?
    var onRestart: ((PaneView) -> Void)?

    init(session: Session, app: AppModel) {
        sessionId = session.id
        self.app = app
        attachedTo = app.connections
        super.init(frame: .zero)
        wantsLayer = true
        buildTerminal(session)
        buildEndedOverlay()
        ended.translatesAutoresizingMaskIntoConstraints = false; addSubview(ended)
        NSLayoutConstraint.activate([ended.centerXAnchor.constraint(equalTo: centerXAnchor), ended.centerYAnchor.constraint(equalTo: centerYAnchor)])
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        update(session)
        track(owner: self) { [app] in app.connections } changed: { [weak self] _ in self?.settle() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private lazy var preview = PathPreview(app: app)

    private static func terminal(_ s: Session) -> GhosttyTerminalView {
        let kelp = Bundle.main.bundleURL.appendingPathComponent(Bundle.main.bundleIdentifier == nil ? "kelp" : "Contents/MacOS/kelp").path
        return GhosttyTerminalView(command: IDE.shellWord(kelp) + " attach \(s.id)", cwd: s.cwd,
                                   env: ["KELP_SOCKET": Paths.socket.path, "KELP_HOME": Paths.root.path])
    }

    private func buildTerminal(_ s: Session) {
        let id = s.id, g = Self.terminal(s)
        ghostty = g
        g.translatesAutoresizingMaskIntoConstraints = false
        addSubview(g, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([g.topAnchor.constraint(equalTo: topAnchor), g.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     g.trailingAnchor.constraint(equalTo: trailingAnchor), g.bottomAnchor.constraint(equalTo: bottomAnchor)])
        g.onExit = { [weak self] in self?.attached = false; self?.settle() }
        g.onSearch = { [weak self] in self?.searchEvent($0) }
        // Paths the agent prints are its folder's: its own worktree once it went into one.
        let cwd = { [app] in app.session(id)?.currentDir ?? s.cwd }, wid = s.worktreeId
        let projects = { [app] in app.repos.map(\.path) }, app = app
        g.onOpenURL = { Self.openLink($0, cwd: cwd(), elsewhere: projects(), in: app) }
        g.onPasteRefused = { Banner.show(String(localized: "Not pasted: a program put these lines on the clipboard, and this terminal would run them as typed. Copy them yourself to paste here.")) }
        g.onOpenPath = { token, flags in TerminalPaths.open(token, cwd: cwd(), elsewhere: projects(), flags: flags, in: app) }
        g.onHoverWord = { [weak self, weak g] tokens, rect in
            guard let self, let g else { return }
            self.preview.show(tokens, rect: rect, in: g, cwd: cwd(), worktree: wid)
        }
    }

    private func buildEndedOverlay() {
        let l = endedLabel
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = .secondaryLabelColor
        let b = restartButton
        b.title = String(localized: "Restart")
        b.target = self
        b.action = #selector(restartTapped)
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil); b.imagePosition = .imageLeading
        let c = NSButton(title: String(localized: "Close"), target: self, action: #selector(closeTapped)); c.bezelStyle = .rounded
        let buttons = NSStackView(views: [b, c]); buttons.spacing = 8
        ended.orientation = .vertical; ended.spacing = 10
        [l, buttons].forEach { ended.addArrangedSubview($0) }
        ended.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        ended.wantsLayer = true; ended.layer?.cornerRadius = 10
        ended.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        ended.isHidden = true
    }

    /// A new connection may be a new daemon (an update, Restart Background Service, a crash), whose session this stream
    /// no longer reaches — libghostty reports the attach's exit only after a key press, so the connection is the sign.
    /// So is a pause: the daemon hangs up the terminals of a session it pauses (its workspace archived or closed).
    /// The session living on, attach again: only on screen, a hidden tab attaches when shown (a restart mustn't wake
    /// every paused agent). A paused one attaches again when it's shown next (which wakes it, as opening any paused tab
    /// does) or on Resume, never on screen right after its pause. Against the same daemon that's one history replay,
    /// nothing lost. Ended: "Session ended".
    private func settle(shown: Bool = false) {
        let s = app.session(sessionId), m = app
        if s?.status == .hibernated, let was = lastStatus, was != .hibernated { attached = false }
        lastStatus = s?.status
        if let s, s.status != .exited, m.connected, window != nil, m.connections != attachedTo || shown && !attached { reattach(s) }
        let paused = !attached && s?.status == .hibernated
        ended.isHidden = attached && s?.status != .exited
        // Its agent still runs in tmux on the host (Session.connectionLost): Reconnect attaches to it again.
        let lost = s?.connectionLost == true
        endedLabel.stringValue = paused ? String(localized: "Paused") : lost ? String(localized: "Connection lost") : String(localized: "Session ended")
        restartButton.title = paused ? String(localized: "Resume") : lost ? String(localized: "Reconnect") : String(localized: "Restart")
        restartButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "arrow.clockwise", accessibilityDescription: nil)
    }

    private func reattach(_ s: Session) {
        let focused = ghostty.map { window?.firstResponder === $0 } ?? false
        findBar?.removeFromSuperview(); findBar = nil   // it searched the old terminal
        ghostty?.removeFromSuperview()
        attached = true; attachedTo = app.connections
        buildTerminal(s)
        if focused { focus() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ended.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
        settle(shown: true)
        offScreen?.cancel(); offScreen = nil
        guard window == nil, let minutes = app.settings.number("sessions.hibernateMinutes"), minutes > 0 else { return }
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
        findBar?.removeFromSuperview(); findBar = nil
        ghostty?.removeFromSuperview(); ghostty = nil
        attached = false
    }

    /// A link ⌘-clicked in the terminal: local pages open as a browser tab, the rest in the default browser; ⌥ swaps
    /// the two. Files open as a tab, ⌥ or not. Nothing else opens: a program prints these links (OSC 8 hides the target
    /// behind any text), and an app, a .command file or another app's scheme would run. A link without a scheme is a
    /// path from `cwd` (or another project's, `TerminalPaths.resolve`): one Ghostty found in the text ("banner/x.html"),
    /// or an agent's Markdown link to its own file.
    static func openLink(_ url: URL, cwd: String, elsewhere: [String], in app: AppModel) {
        if url.scheme == nil {
            let path = url.path(percentEncoded: false)
            if !TerminalPaths.open(path, cwd: cwd, elsewhere: elsewhere, flags: NSEvent.modifierFlags, in: app) {
                Banner.show(String(localized: "No file “\(path)” in \((cwd as NSString).abbreviatingWithTildeInPath) or your other projects."))
            }
            return
        }
        let option = NSEvent.modifierFlags.contains(.option)
        switch PreviewLinks.target(url) {
        case .web(let s):
            let local = url.host == "localhost" || url.host == "127.0.0.1"
            if local != option { app.workbench.open(s, split: .right) } else { NSWorkspace.shared.open(url) }
        case .file(let p): app.workbench.open(TabURI.file(p), split: .right)
        case .mail(let m): NSWorkspace.shared.open(m)
        case .refused: PreviewLinks.refuse(url)
        }
    }

    func update(_: Session) { settle() }

    func focus() { ghostty?.focus() }

    /// Columns × rows now; the last one seen anywhere (`app.workbench.terminalGrid`) sizes the next terminal before it's on screen.
    var gridSize: (cols: Int, rows: Int)? {
        if let g = ghostty?.gridSize { app.workbench.terminalGrid = g; return g }
        return nil
    }

    /// What's on screen (tests, "copy context" fallback).
    var visibleText: String { ghostty?.visibleText ?? "" }

    /// Text dropped or dictated into the prompt.
    func insert(_ text: String) { ghostty?.insert(text) }

    /// Right-click where the program in the terminal doesn't take the mouse itself, like Terminal's menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let g = ghostty else { return nil }
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Copy"), action: #selector(GhosttyTerminalView.copy(_:)), keyEquivalent: "").target = g
        m.items.last?.isEnabled = g.hasSelection; m.autoenablesItems = false
        m.addItem(withTitle: String(localized: "Paste"), action: #selector(GhosttyTerminalView.paste(_:)), keyEquivalent: "").target = g
        m.addItem(withTitle: String(localized: "Select All"), action: #selector(GhosttyTerminalView.selectAll(_:)), keyEquivalent: "").target = g
        m.addItem(.separator())
        m.add(String(localized: "Find…")) { [weak self] in self?.showFind(nil) }
        m.addItem(.separator())
        m.add(String(localized: "Split Right")) { [weak self] in self?.focus(); self?.app.workbench.editor?.splitFocused(.right) }
        m.add(String(localized: "Split Down")) { [weak self] in self?.focus(); self?.app.workbench.editor?.splitFocused(.down) }
        return m
    }

    // MARK: find (Edit › Find reaches the pane through the responder chain)
    private var findBar: FindBar?

    @objc func performFindPanelAction(_ sender: Any?) {
        guard let g = ghostty else { return }
        switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
        case .next?: g.perform(action: "navigate_search:next")
        case .previous?: g.perform(action: "navigate_search:previous")
        case .setFindString?: g.perform(action: "search_selection")   // Ghostty answers with start_search and the text
        default: showFind(nil)
        }
    }

    private func showFind(_ needle: String?) {
        guard let g = ghostty else { return }
        let bar = findBar ?? {
            let b = FindBar()
            b.onSearch = { g.perform(action: "search:" + $0) }
            b.onStep = { g.perform(action: "navigate_search:" + ($0 ? "next" : "previous")) }
            b.onClose = { [weak self] in g.perform(action: "end_search"); self?.focus() }
            b.translatesAutoresizingMaskIntoConstraints = false; addSubview(b)
            NSLayoutConstraint.activate([b.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
                                         b.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -14)])
            findBar = b; return b
        }()
        bar.begin(needle)
    }

    private func searchEvent(_ e: GhosttyTerminalView.SearchEvent) {
        switch e {
        case .started(let needle): showFind(needle)
        case .ended: findBar?.isHidden = true
        case .total(let n): findBar?.total = n
        case .selected(let n): findBar?.selected = n
        }
    }

    @objc private func closeTapped() { onClose?(self) }
    /// Resume on a paused pane attaches again (and so wakes the agent); otherwise the session starts over.
    @objc private func restartTapped() {
        if !attached, let s = app.session(sessionId), s.status == .hibernated { reattach(s); settle() } else { onRestart?(self) }
    }

    // MARK: drops: files/images/text into the agent's prompt
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var paths = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path) ?? []
        if paths.isEmpty, let png = TerminalPaste.savedImage(pb) { paths = [png] }
        if paths.isEmpty, let text = pb.string(forType: .string) { insert(text); return true }
        guard !paths.isEmpty else { return false }
        insert(TerminalPaste.paths(paths))
        focus()
        return true
    }
}
