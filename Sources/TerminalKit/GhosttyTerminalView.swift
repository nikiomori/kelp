import AppKit
import GhosttyKit

/// Colors and font from the IDE's theme and settings (nil = keep Ghostty's config / defaults).
public struct TerminalAppearance: Equatable, Sendable {
    public var useGhosttyConfig = true
    public var background: String?, foreground: String?, cursor: String?, selection: String?
    public var palette: [String] = []
    public var fontFamily: String?, fontSize: Double?
    public var cursorStyle: String?
    public var optionAsAlt = false
    public init() {}

    var configText: String {
        var lines: [String] = []
        if let v = background { lines.append("background = \(v)") }
        if let v = foreground { lines.append("foreground = \(v)") }
        if let v = cursor { lines.append("cursor-color = \(v)") }
        if let v = selection { lines.append("selection-background = \(v)") }
        for (i, c) in palette.prefix(16).enumerated() { lines.append("palette = \(i)=\(c)") }
        if let v = fontFamily, !v.isEmpty { lines.append("font-family = \(v)") }
        if let v = fontSize { lines.append("font-size = \(v)") }
        if let v = cursorStyle { lines.append("cursor-style = \(v)") }
        if optionAsAlt { lines.append("macos-option-as-alt = true") }
        return lines.joined(separator: "\n")
    }
}

// Terminal backend on libghostty (Metal rendering, Ghostty's input and selection). Input handling follows
// Ghostty's own macOS SurfaceView (MIT): https://github.com/ghostty-org/ghostty/tree/main/macos/Sources/Ghostty

/// One libghostty app per process; surfaces (terminal views) hang off it.
@MainActor
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()
    public private(set) var app: ghostty_app_t?
    private let surfaces = NSHashTable<GhosttyTerminalView>.weakObjects()
    /// Set before the first terminal opens; `configure` changes it later.
    public static var appearance = TerminalAppearance()
    public private(set) static var started = false
    /// Copying from a terminal drops what TUIs draw around text: borders, the agent's gutter, trailing spaces.
    public static var cleanCopy = true
    /// The pasteboard's `changeCount` after a program in a terminal last wrote it (OSC 52), while nothing else has.
    static var programCopy: Int?

    /// Applies a new appearance to every open terminal.
    public func configure(_ a: TerminalAppearance) {
        Self.appearance = a
        guard let app else { return }
        let cfg = Self.makeConfig()
        ghostty_app_update_config(app, cfg)
        for v in surfaces.allObjects { if let s = v.surface { ghostty_surface_update_config(s, cfg) } }
        ghostty_config_free(cfg)
    }

    func register(_ v: GhosttyTerminalView) { surfaces.add(v) }

    private static func makeConfig() -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-ghostty-defaults-\(getpid()).conf")
        try? defaults.write(to: d, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, d.path)   // first: the user's Ghostty config may change them
        if appearance.useGhosttyConfig { ghostty_config_load_default_files(cfg) }   // the user's Ghostty theme, font, cursor…
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-ghostty-\(getpid()).conf")
        try? (overrides + "\n" + appearance.configText).write(to: f, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, f.path)
        ghostty_config_finalize(cfg)
        return cfg
    }

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { return }
        Self.started = true
        let cfg = Self.makeConfig()
        setUp(cfg)
    }

    /// Under the user's Ghostty config: text keeps 3:1 contrast with its background, so colours picked for a dark
    /// terminal (Claude Code's near-white greys) stay readable on a light one, and dark ones on a dark one.
    private static let defaults = "minimum-contrast = 3\n"

    // App shortcuts (⌘T, ⌘D, ⌘W…) belong to Kelp; Ghostty keeps only terminal ones.
    // ⇧↩ types a line feed: a new line in agent prompts (Claude Code, Codex) instead of sending the message.
    static let overrides = """
        keybind = clear
        keybind = super+c=copy_to_clipboard
        keybind = super+v=paste_from_clipboard
        keybind = super+a=select_all
        keybind = super+equal=increase_font_size:1
        keybind = super+plus=increase_font_size:1
        keybind = super+minus=decrease_font_size:1
        keybind = super+zero=reset_font_size
        keybind = super+k=clear_screen
        keybind = shift+page_up=scroll_page_up
        keybind = shift+page_down=scroll_page_down
        keybind = shift+enter=text:\n
        keybind = super+home=scroll_to_top
        keybind = super+end=scroll_to_bottom
        confirm-close-surface = false
        clipboard-paste-protection = true
        clipboard-write = ask
        window-padding-x = 12
        window-padding-y = 8
        """

    private func setUp(_ cfg: ghostty_config_t?) {
        var rt = ghostty_runtime_config_s()
        rt.userdata = nil
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { if let a = GhosttyRuntime.shared.app { ghostty_app_tick(a) } } } }
        rt.action_cb = { _, target, action in
            MainActor.assumeIsolated { GhosttyRuntime.shared.handle(target, action) }
        }
        rt.read_clipboard_cb = { ud, _, state, mimes, count, _ in
            MainActor.assumeIsolated { GhosttyTerminalView.from(ud)?.readClipboard(state: state, mimes: mimes, count: count) ?? GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        }
        rt.confirm_read_clipboard_cb = { ud, confirm, state, request in
            MainActor.assumeIsolated { GhosttyTerminalView.from(ud)?.confirmClipboard(confirm, state: state, request: request) }
        }
        // `fromProgram`: an OSC 52 write (Claude Code copies that way over ssh), which `clipboard-write = ask` flags.
        rt.write_clipboard_cb = { ud, _, contents, count, fromProgram in
            guard let contents, count > 0 else { return }
            var text: String?
            for i in 0..<count {
                let c = contents[i]
                guard let mime = c.mime.map({ String(cString: $0) }), mime.hasPrefix("text/plain"), let data = c.data else { continue }
                text = String(bytes: UnsafeRawBufferPointer(start: data, count: c.len), encoding: .utf8)
            }
            if let raw = text {
                let view = MainActor.assumeIsolated { GhosttyTerminalView.from(ud) }   // Ghostty writes on the main thread
                // Later: the selection is read under the lock Ghostty holds while it writes.
                DispatchQueue.main.async { [weak view] in MainActor.assumeIsolated {
                    let text = GhosttyRuntime.cleanCopy && !fromProgram
                        ? TerminalCopy.clean(raw, from: view?.selectionColumn ?? 0, columns: view?.gridSize?.cols) : raw
                    let pb = NSPasteboard.general
                    pb.clearContents(); pb.setString(text, forType: .string)
                    GhosttyRuntime.programCopy = fromProgram ? pb.changeCount : nil
                } }
            }
        }
        rt.close_surface_cb = { ud, _ in
            MainActor.assumeIsolated { GhosttyTerminalView.from(ud)?.onExit?() }
        }
        app = ghostty_app_new(&rt, cfg)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let a = GhosttyRuntime.shared.app { ghostty_app_set_focus(a, true) } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let a = GhosttyRuntime.shared.app { ghostty_app_set_focus(a, false) } }
        }
    }

    private func handle(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let view: GhosttyTerminalView? = target.tag == GHOSTTY_TARGET_SURFACE
            ? target.target.surface.flatMap { GhosttyTerminalView.from(ghostty_surface_userdata($0)) } : nil
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let t = action.action.set_title.title { view?.onTitle?(String(cString: t)) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let p = u.url else { return false }
            if let s = String(bytes: UnsafeRawBufferPointer(start: p, count: Int(u.len)), encoding: .utf8), let url = URL(string: s) { if let h = view?.onOpenURL { h(url) } else { NSWorkspace.shared.open(url) } }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            if let view { view.cursor = GhosttyTerminalView.cursor(for: action.action.mouse_shape); view.window?.invalidateCursorRects(for: view) }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            view?.cellSize = NSSize(width: Double(action.action.cell_size.width), height: Double(action.action.cell_size.height))
            return true
        case GHOSTTY_ACTION_RING_BELL:
            return true   // agents ring constantly; status dots carry that signal
        case GHOSTTY_ACTION_START_SEARCH:
            view?.onSearch?(.started(action.action.start_search.needle.map { String(cString: $0) } ?? ""))
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            view?.onSearch?(.ended)
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            view?.onSearch?(.total(Int(action.action.search_total.total)))
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            view?.onSearch?(.selected(Int(action.action.search_selected.selected)))
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            let s = action.action.scrollbar
            view?.scrollIndicator.show(total: Double(s.total), offset: Double(s.offset), length: Double(s.len))
            return true
        default:
            return false
        }
    }
}

@MainActor
public final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
    public private(set) var surface: ghostty_surface_t?
    public var onTitle: ((String) -> Void)?
    public var onOpenURL: ((URL) -> Void)?
    public var onExit: (() -> Void)?
    public var onFocus: (() -> Void)?
    /// Find in the scrollback: Ghostty reports matches as it searches (-1 = not known yet).
    public enum SearchEvent: Sendable { case started(String), ended, total(Int), selected(Int) }
    public var onSearch: ((SearchEvent) -> Void)?
    /// ⌘-click on text Ghostty doesn't see as a link (`Sources/App.swift:12`): true if the app opened it.
    public var onOpenPath: ((String, NSEvent.ModifierFlags) -> Bool)?
    /// The pointer came to rest on a word (a path, maybe: what it may be, see `word(at:)`), or left it (none); the rect
    /// is the word's part on that row, in this view.
    public var onHoverWord: (([String], NSRect) -> Void)?
    /// ⌘V was refused: a program put that text on the clipboard and here its line breaks would run it.
    public var onPasteRefused: (() -> Void)?
    private var hoverTimer: Timer?
    private var hovered: NSRect?
    private var clickTaken = false
    let scrollIndicator = ScrollIndicator()
    private let sizeBadge = SizeBadge()
    private var shownGrid: (cols: Int, rows: Int)?
    private var placedAt = Date.distantFuture
    var cellSize = NSSize(width: 8, height: 16)
    static let padX = 12.0, padY = 8.0   // window-padding in `GhosttyRuntime.overrides`
    var cursor: NSCursor = .iBeam
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var trackingArea: NSTrackingArea?

    /// True once a terminal has started libghostty (so appearance changes don't start it just to apply).
    public static var isLoaded: Bool { GhosttyRuntime.started }

    /// Runs `command` (through the login shell, like Ghostty) in `cwd` with extra environment.
    public init(command: String, cwd: String, env: [String: String] = [:]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        for v in [scrollIndicator, sizeBadge] as [NSView] { addSubview(v) }
        guard let app = GhosttyRuntime.shared.app else { return }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.wait_after_command = false
        let cKeys = env.keys.map { strdup($0) }, cValues = env.keys.map { strdup(env[$0] ?? "") }
        defer { (cKeys + cValues).forEach { free($0) } }
        var vars = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0, value: $1) }
        GhosttyRuntime.shared.register(self)
        surface = command.withCString { c in cwd.withCString { d in
            vars.withUnsafeMutableBufferPointer { vp in
                cfg.command = c; cfg.working_directory = d
                cfg.env_vars = vp.baseAddress; cfg.env_var_count = vp.count
                return ghostty_surface_new(app, &cfg)
            }
        } }
    }
    public required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        if let surface { ghostty_surface_free(surface) }
    }

    static func from(_ ud: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
        guard let ud else { return nil }
        return Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    // MARK: size, focus

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        setVisible(true)   // AppKit can miss an occlusion change (Spaces, full screen): typing here means it's on screen
        onFocus?(); return true
    }
    public override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }
    public func focus() { window?.makeFirstResponder(self) }

    public var hasSelection: Bool { surface.map(ghostty_surface_has_selection) ?? false }

    /// Columns × rows on screen now (nil before the first layout).
    public var gridSize: (cols: Int, rows: Int)? {
        guard let surface else { return nil }
        let s = ghostty_surface_size(surface)
        return s.columns > 0 && s.rows > 0 ? (Int(s.columns), Int(s.rows)) : nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); updateSize()
        placedAt = window == nil ? .distantFuture : Date()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        updateOcclusion()
        guard let w = window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOcclusion() }
        }
    }

    // A terminal nobody can see (other tab, hidden or minimized window) stops drawing; its process runs on.
    private var occlusionObserver: NSObjectProtocol?
    private var lastVisible: Bool?
    private func updateOcclusion() { setVisible(window?.occlusionState.contains(.visible) == true) }
    private func setVisible(_ v: Bool) {
        guard let surface, v != lastVisible else { return }
        lastVisible = v
        ghostty_surface_set_occlusion(surface, v)
    }
    public override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); updateSize(); layoutOverlays() }

    /// The scroll position along the right edge, and "120 × 40" in the middle while the pane is being resized.
    private func layoutOverlays() {
        scrollIndicator.frame = NSRect(x: bounds.width - 9, y: 2, width: 7, height: max(0, bounds.height - 4))
        guard let g = gridSize else { return }
        defer { shownGrid = g }
        // Not when it first appears or a tab is switched to: only a resize of a terminal already on screen.
        guard let old = shownGrid, old != g, Date().timeIntervalSince(placedAt) > 1 else { return }
        sizeBadge.show("\(g.cols) × \(g.rows)", in: bounds)
    }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateSize()
    }
    private func updateSize() {
        guard let surface, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let fb = convertToBacking(bounds)
        ghostty_surface_set_content_scale(surface, fb.width / bounds.width, fb.height / bounds.height)
        ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
    }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow
        default: .iBeam
        }
    }

    public override func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(t); trackingArea = t
        super.updateTrackingAreas()
    }

    // MARK: text access

    /// Visible screen text (tests, "send selection").
    public var visibleText: String { readText(GHOSTTY_POINT_VIEWPORT) }
    public var selection: String? {
        guard let surface else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        return String(cString: t.text)
    }
    /// The column the selection starts at: its first line leaves out what's before it.
    var selectionColumn: Int {
        guard let surface else { return 0 }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return 0 }
        defer { ghostty_surface_free_text(surface, &t) }
        let cw = Double(ghostty_surface_size(surface).cell_width_px) / (window?.backingScaleFactor ?? 2)
        return cw > 0 ? max(0, Int(((t.tl_px_x - Self.padX) / cw).rounded())) : 0   // tl_px_x: points, padding included
    }
    private func readText(_ tag: ghostty_point_tag_e) -> String {
        guard let surface else { return "" }
        var t = ghostty_text_s()
        let sel = ghostty_selection_s(top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                                      bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &t) else { return "" }
        defer { ghostty_surface_free_text(surface, &t) }
        return String(cString: t.text)
    }
    /// A text area to Accessibility, as in Ghostty: dictation apps (MacWhisper, Superwhisper…) paste only into a focused
    /// text field or area, and VoiceOver reads the screen.
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityValue() -> Any? { visibleText }
    /// Type text as if pasted by the user (used for drops into the prompt).
    public func insert(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    // MARK: mouse

    static func mods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = f.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    /// Under a program that takes the mouse (Claude Code, vim) Ghostty looks for links only while ⇧ is held, so ⌘
    /// alone gets ⇧ added: ⌘-click opens a link there as it does at a shell prompt (Ghostty drops the ⇧ when it checks).
    nonisolated static func linkMods(_ f: NSEvent.ModifierFlags, captured: Bool) -> NSEvent.ModifierFlags {
        captured && f.intersection([.shift, .control, .option, .command]) == .command ? f.union(.shift) : f
    }
    private func mouseMods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        Self.mods(Self.linkMods(f, captured: surface.map(ghostty_surface_mouse_captured) ?? false))
    }

    public override func mouseDown(with e: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        endHover()
        if e.modifierFlags.contains(.command), let w = word(at: convert(e.locationInWindow, from: nil)), open(w.texts, e.modifierFlags) {
            clickTaken = true; return
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mouseMods(e.modifierFlags))
    }
    /// ⌘-click on a path: the app opens it. On a link a program broke across rows, the whole link — Ghostty would open
    /// the clicked row's part; it handles links on one row and the ones it wrapped itself. A program breaks only a word
    /// longer than the row: a shorter one is a link that just filled its row, and the next row's word isn't part of it.
    private func open(_ texts: [String], _ flags: NSEvent.ModifierFlags) -> Bool {
        if texts.count > 1, texts[0].count > gridSize?.cols ?? .max, texts[0].contains("://"), let u = URL(string: texts[0]) {
            if let h = onOpenURL { h(u) } else { NSWorkspace.shared.open(u) }
            return true
        }
        return texts.contains { onOpenPath?($0, flags) == true }
    }
    public override func mouseUp(with e: NSEvent) {
        if clickTaken { clickTaken = false; return }
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mouseMods(e.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }
    public override func rightMouseDown(with e: NSEvent) {
        guard let surface, ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(e.modifierFlags)) else { return super.rightMouseDown(with: e) }
    }
    public override func rightMouseUp(with e: NSEvent) {
        guard let surface, ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(e.modifierFlags)) else { return super.rightMouseUp(with: e) }
    }
    public override func otherMouseDown(with e: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, Self.mods(e.modifierFlags))
    }
    public override func otherMouseUp(with e: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, Self.mods(e.modifierFlags))
    }
    public override func mouseMoved(with e: NSEvent) {
        guard let surface else { return }
        let p = convert(e.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, mouseMods(e.modifierFlags))
        scheduleHover(p, buttons: NSEvent.pressedMouseButtons)
    }

    /// Half a second at rest on a word asks the app whether it's worth a preview; moving off it closes that.
    private func scheduleHover(_ p: NSPoint, buttons: Int) {
        hoverTimer?.invalidate()
        if let r = hovered, !r.insetBy(dx: -2, dy: -2).contains(p) { endHover() }
        guard buttons == 0, onHoverWord != nil, hovered == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let w = self.word(at: p) else { return }
                self.hovered = w.rect; self.onHoverWord?(w.texts, w.rect)
            }
        }
    }
    private func endHover() {
        hoverTimer?.invalidate()
        guard hovered != nil else { return }
        hovered = nil; onHoverWord?([], .zero)
    }

    /// The run of characters under `p` up to blanks and brackets, with its parts on the rows it wraps onto — so
    /// "App.swift:12:5" stays whole (Ghostty's own words stop at ":"), and so does a path Claude Code broke in two.
    /// `texts`: the joined word first, then the row's own part (see `TerminalCopy.wrappedWord`); `rect`: that part.
    public func word(at p: NSPoint) -> (texts: [String], rect: NSRect)? {
        guard let surface else { return nil }
        let s = ghostty_surface_size(surface), scale = window?.backingScaleFactor ?? 2
        let cw = Double(s.cell_width_px) / scale, ch = Double(s.cell_height_px) / scale
        guard cw > 0, ch > 0, s.columns > 0 else { return nil }
        let padX = Self.padX, padY = Self.padY
        let col = Int((p.x - padX) / cw), row = Int((bounds.height - p.y - padY) / ch)
        guard row >= 0, row < Int(s.rows), col >= 0, col < Int(s.columns) else { return nil }
        let rowText = { (y: Int) -> String? in
            guard y >= 0, y < Int(s.rows) else { return nil }
            var t = ghostty_text_s()
            let sel = ghostty_selection_s(top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(y)),
                                          bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(s.columns - 1), y: UInt32(y)),
                                          rectangle: false)
            guard ghostty_surface_read_text(surface, sel, &t) else { return nil }
            defer { ghostty_surface_free_text(surface, &t) }
            return String(cString: t.text)
        }
        guard let w = TerminalCopy.wrappedWord(rows: rowText, row: row, at: col, columns: Int(s.columns)) else { return nil }
        let rect = NSRect(x: padX + Double(w.start) * cw, y: bounds.height - padY - Double(row + 1) * ch, width: Double(w.width) * cw, height: ch)
        return (w.texts, rect)
    }
    public override func mouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    public override func rightMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    public override func otherMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    public override func mouseEntered(with e: NSEvent) { mouseMoved(with: e) }
    public override func mouseExited(with e: NSEvent) {
        endHover()
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(e.modifierFlags))
    }
    public override func scrollWheel(with e: NSEvent) {
        guard let surface else { return }
        var x = e.scrollingDeltaX, y = e.scrollingDeltaY
        let precise = e.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        let phases: [(NSEvent.Phase, Int32)] = [(.began, 1), (.stationary, 2), (.changed, 3), (.ended, 4), (.cancelled, 5), (.mayBegin, 6)]
        let momentum = phases.first { $0.0 == e.momentumPhase }?.1 ?? 0
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
    }
    public override func pressureChange(with e: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(e.stage), Double(e.pressure))
    }

    // MARK: keyboard (ported from Ghostty's SurfaceView)

    private func keyEvent(_ e: NSEvent, _ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(e.keyCode)
        k.text = nil; k.composing = false
        k.mods = Self.mods(e.modifierFlags)
        k.consumed_mods = Self.mods((translationMods ?? e.modifierFlags).subtracting([.control, .command]))
        k.unshifted_codepoint = 0
        if e.type == .keyDown || e.type == .keyUp, let c = e.characters(byApplyingModifiers: [])?.unicodeScalars.first { k.unshifted_codepoint = c.value }
        return k
    }

    /// Control characters are encoded by Ghostty itself; function keys (PUA) carry no text.
    private static func characters(_ e: NSEvent) -> String? {
        guard let chars = e.characters else { return nil }
        if chars.count == 1, let s = chars.unicodeScalars.first {
            if s.value < 0x20 { return e.characters(byApplyingModifiers: e.modifierFlags.subtracting(.control)) }
            if s.value >= 0xF700 && s.value <= 0xF8FF { return nil }
        }
        return chars
    }

    @discardableResult
    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil, text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var k = keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        k.composing = composing
        if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20 || text.count > 1 {
            return text.withCString { k.text = $0; return ghostty_surface_key(surface, k) }
        }
        return ghostty_surface_key(surface, k)
    }

    private func committedText(_ text: String) {
        guard let surface else { return }
        var k = ghostty_input_key_s()
        k.action = GHOSTTY_ACTION_PRESS; k.mods = GHOSTTY_MODS_NONE; k.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { k.text = $0; _ = ghostty_surface_key(surface, k) }
    }

    public override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }
        if window?.isKeyWindow == true { setVisible(true) }
        // Option-as-alt and friends: let Ghostty say which modifiers take part in translating to text.
        let tm = ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags))
        var translationMods = event.modifierFlags
        for (flag, bit) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER)] {
            if tm.rawValue & bit.rawValue != 0 { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent = translationMods == event.modifierFlags ? event : (NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods, timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event)
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])   // IMEs (Korean, Japanese, dead keys) speak through this
        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                if composing, text.count == 1, (text.unicodeScalars.first?.value ?? 0x20) < 0x20 { continue }
                if markedBefore { committedText(text) } else { keyAction(action, event: event, translationEvent: translationEvent, text: text) }
            }
        } else {
            if composing, let c = event.characters, c.count == 1, (c.unicodeScalars.first?.value ?? 0x20) < 0x20 { return }
            keyAction(action, event: event, translationEvent: translationEvent, text: Self.characters(translationEvent), composing: composing)
        }
    }

    public override func keyUp(with event: NSEvent) { keyAction(GHOSTTY_ACTION_RELEASE, event: event) }

    public override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let pressed = Self.mods(event.modifierFlags).rawValue & mod != 0
        guard let surface else { return }
        var k = keyEvent(event, pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        k.mods = mouseMods(event.modifierFlags)   // ⌘ lights up the link under a resting pointer too (see linkMods)
        _ = ghostty_surface_key(surface, k)
    }

    // MARK: Edit menu (Copy / Paste / Select All reach the terminal from the menu bar too, not only as ⌘C / ⌘V)

    private func ghosttyAction(_ name: String) { perform(action: name) }
    /// A Ghostty binding action by name ("search:text", "navigate_search:next", "end_search"…).
    @discardableResult
    public func perform(action name: String) -> Bool {
        guard let surface else { return false }
        return name.withCString { ghostty_surface_binding_action(surface, $0, UInt(name.utf8.count)) }
    }
    @objc public func copy(_ sender: Any?) { ghosttyAction("copy_to_clipboard") }
    @objc public func paste(_ sender: Any?) { ghosttyAction("paste_from_clipboard") }
    @objc public override func selectAll(_ sender: Any?) { ghosttyAction("select_all") }

    /// ⌘-keys: Ghostty's own bindings (copy, paste, font size) go to the terminal; everything else to the menus.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }
        var k = keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { k.text = $0; return ghostty_surface_key_is_binding(surface, k, &flags) }
        if isBinding { keyDown(with: event); return true }
        // Control-Return and Control-/ would otherwise be eaten by AppKit.
        if event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command), ["\r", "/"].contains(event.charactersIgnoringModifiers ?? "") {
            keyDown(with: event); return true
        }
        return false
    }

    // MARK: NSTextInputClient

    public func hasMarkedText() -> Bool { markedText.length > 0 }
    public func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let v = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: v) }
        else if let v = string as? String { markedText = NSMutableAttributedString(string: v) }
        if keyTextAccumulator == nil { syncPreedit() }
    }
    public func unmarkText() { if markedText.length > 0 { markedText.mutableString.setString(""); syncPreedit() } }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let r = NSRect(x: x, y: bounds.height - y, width: 0, height: max(h, cellSize.height))
        return window?.convertToScreen(convert(r, to: nil)) ?? r
    }
    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil { keyTextAccumulator?.append(chars); return }
        if !chars.isEmpty { committedText(chars) }
    }
    public override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp { NSApp.sendEvent(current) }
    }
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: clipboard

    func readClipboard(state: UnsafeMutableRawPointer?, mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> ghostty_clipboard_read_result_e {
        guard let surface, let text = TerminalPaste.text(from: .general) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        let data = text.utf8CString   // its length goes along: a NUL inside the text must not cut it short
        data.withUnsafeBufferPointer { d in
            "text/plain;charset=utf-8".withCString { mime in
                var content = ghostty_clipboard_content_s(mime: mime, data: d.baseAddress, len: d.count - 1)
                withUnsafePointer(to: &content) { cp in
                    var done = ghostty_clipboard_complete_s()
                    // Not confirmed: Ghostty applies its policy (`clipboard-read = ask` for OSC 52 / Kitty reads, paste
                    // protection) and asks `confirmClipboard`.
                    done.contents = cp; done.contents_len = 1; done.confirmed = false
                    ghostty_surface_complete_clipboard_request(surface, &done, state)
                }
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty asks before a paste that would run as typed (a line break, no bracketed paste) and before a program reads
    /// the clipboard or writes it the Kitty way. The paste goes through, unless a program put that text there: lines you
    /// never saw mustn't run on ⌘V. The rest is refused.
    func confirmClipboard(_ c: UnsafePointer<ghostty_clipboard_confirm_s>?, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let surface else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let c else { ghostty_surface_deny_clipboard_request(surface, state); return }
        if GhosttyRuntime.programCopy == NSPasteboard.general.changeCount {
            ghostty_surface_deny_clipboard_request(surface, state); onPasteRefused?(); return
        }
        var done = ghostty_clipboard_complete_s()
        done.contents = c.pointee.contents; done.contents_len = c.pointee.contents_len; done.confirmed = true
        ghostty_surface_complete_clipboard_request(surface, &done, state)
    }
}
