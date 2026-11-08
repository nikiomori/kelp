import AppKit
import GhosttyKit

@MainActor
public final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
    public private(set) var surface: ghostty_surface_t?
    private let link = SurfaceLink()
    public var onTitle: ((String) -> Void)?
    public var onOpenURL: ((URL) -> Void)?
    public var onExit: (() -> Void)?
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
    var shownGrid: (cols: Int, rows: Int)?
    private var placedAt = Date.distantFuture
    var cellSize = NSSize(width: 8, height: 16)
    static let padX = 12.0, padY = 8.0   // window-padding in `GhosttyRuntime.overrides`
    var cursor: NSCursor = .iBeam
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var trackingArea: NSTrackingArea?
    var echoWatch: Timer?

    /// True once a terminal has started libghostty (so appearance changes don't start it just to apply).
    public static var isLoaded: Bool { GhosttyRuntime.started }

    /// Runs `command` (through the login shell, like Ghostty) in `cwd` with extra environment.
    public init(command: String, cwd: String, env: [String: String] = [:]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(takeSize), name: Self.sizeReleased, object: nil)
        for view in [scrollIndicator, sizeBadge] as [NSView] { addSubview(view) }
        guard let app = GhosttyRuntime.shared.app else { return }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        link.view = self
        cfg.userdata = Unmanaged.passUnretained(link).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.wait_after_command = false
        let cKeys = env.keys.map { strdup($0) }, cValues = env.keys.map { strdup(env[$0] ?? "") }
        defer { (cKeys + cValues).forEach { free($0) } }
        var vars = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0, value: $1) }
        GhosttyRuntime.shared.register(self)
        surface = command.withCString { cCommand in
            cwd.withCString { cCwd in
                vars.withUnsafeMutableBufferPointer { vp in
                    cfg.command = cCommand
                    cfg.working_directory = cCwd
                    cfg.env_vars = vp.baseAddress
                    cfg.env_var_count = vp.count
                    return ghostty_surface_new(app, &cfg)
                }
            }
        }
    }
    public required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let observer = occlusionObserver { NotificationCenter.default.removeObserver(observer) }
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        if let surface { GhosttyRuntime.shared.retire(surface, link) }
    }

    static func from(_ ud: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
        guard let ud else { return nil }
        let link = Unmanaged<SurfaceLink>.fromOpaque(ud).takeUnretainedValue()
        link.heard = true
        return link.view
    }

    // MARK: size, focus

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool {
        // Focused only in the key window: another app in front, Ghostty draws this one at most 30 times a second.
        if let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow != false) }
        setVisible(true)   // AppKit can miss an occlusion change (Spaces, full screen): typing here means it's on screen
        return true
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
        let size = ghostty_surface_size(surface)
        return size.columns > 0 && size.rows > 0 ? (Int(size.columns), Int(size.rows)) : nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSize()
        placedAt = window == nil ? .distantFuture : Date()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        updateOcclusion()
        guard let window else { return }
        let center = NotificationCenter.default
        keyObservers = followKey(of: window)
        occlusionObserver = center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOcclusion() }
        }
    }

    var keyObservers: [NSObjectProtocol] = []

    // A terminal nobody can see (other tab, hidden or minimized window) stops drawing; its process runs on.
    private var occlusionObserver: NSObjectProtocol?
    private var lastVisible: Bool?
    private func updateOcclusion() { setVisible(window?.occlusionState.contains(.visible) == true) }
    private func setVisible(_ visible: Bool) {
        guard let surface, visible != lastVisible else { return }
        lastVisible = visible
        ghostty_surface_set_occlusion(surface, visible)
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSize()
        layoutOverlays()
    }

    /// The scroll position along the right edge, and "120 × 40" in the middle while the pane is being resized.
    private func layoutOverlays() {
        scrollIndicator.frame = NSRect(x: bounds.width - 9, y: 2, width: 7, height: max(0, bounds.height - 4))
        guard let grid = gridSize else { return }
        defer { shownGrid = grid }
        // Not when it first appears or a tab is switched to: only a resize of a terminal already on screen.
        guard let old = shownGrid, old != grid, Date().timeIntervalSince(placedAt) > 1 else { return }
        sizeBadge.show("\(grid.cols) × \(grid.rows)", in: bounds)
    }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateSize()
    }
    func updateSize() {
        guard Self.holds == 0, let surface, window != nil, bounds.width > 0, bounds.height > 0 else { return }
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
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    // MARK: text access

    /// Visible screen text (tests, "send selection").
    public var visibleText: String { readText(GHOSTTY_POINT_VIEWPORT) }
    public var selection: String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
    /// The column the selection starts at: its first line leaves out what's before it.
    var selectionColumn: Int {
        guard let surface else { return 0 }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return 0 }
        defer { ghostty_surface_free_text(surface, &text) }
        let cw = Double(ghostty_surface_size(surface).cell_width_px) / (window?.backingScaleFactor ?? 2)
        // tl_px_x: points, padding included
        return cw > 0 ? max(0, Int(((text.tl_px_x - Self.padX) / cw).rounded())) : 0
    }
    func readText(_ tag: ghostty_point_tag_e) -> String {
        read(
            from: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            to: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0))
    }
    func read(from start: ghostty_point_s, to end: ghostty_point_s) -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        guard
            ghostty_surface_read_text(
                surface, ghostty_selection_s(top_left: start, bottom_right: end, rectangle: false), &text)
        else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Type text as if pasted by the user (used for drops into the prompt).
    public func insert(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    // MARK: mouse

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mask: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mask |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mask |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mask |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mask |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mask |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mask |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mask |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mask |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mask |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mask)
    }

    /// Under a program that takes the mouse (Claude Code, vim) Ghostty looks for links only while ⇧ is held, so ⌘
    /// alone gets ⇧ added: ⌘-click opens a link there as it does at a shell prompt (Ghostty drops the ⇧ when it checks).
    nonisolated static func linkMods(_ flags: NSEvent.ModifierFlags, captured: Bool) -> NSEvent.ModifierFlags {
        captured && flags.intersection([.shift, .control, .option, .command]) == .command ? flags.union(.shift) : flags
    }
    private func mouseMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        Self.mods(Self.linkMods(flags, captured: surface.map(ghostty_surface_mouse_captured) ?? false))
    }

    public override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        endHover()
        if event.modifierFlags.contains(.command), let hit = word(at: convert(event.locationInWindow, from: nil)),
            open(hit.texts, event.modifierFlags)
        {
            clickTaken = true
            return
        }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mouseMods(event.modifierFlags))
    }
    /// ⌘-click on a path: the app opens it. On a link a program broke across rows, the whole link — Ghostty would open
    /// the clicked row's part; it handles links on one row and the ones it wrapped itself. A program breaks only a word
    /// longer than the row: a shorter one is a link that just filled its row, and the next row's word isn't part of it.
    private func open(_ texts: [String], _ flags: NSEvent.ModifierFlags) -> Bool {
        if texts.count > 1, texts[0].count > gridSize?.cols ?? .max, texts[0].contains("://"),
            let url = URL(string: texts[0])
        {
            if let handler = onOpenURL { handler(url) } else { NSWorkspace.shared.open(url) }
            return true
        }
        return texts.contains { onOpenPath?($0, flags) == true }
    }
    public override func mouseUp(with event: NSEvent) {
        if clickTaken {
            clickTaken = false
            return
        }
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mouseMods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }
    public override func rightMouseDown(with event: NSEvent) {
        guard let surface,
            ghostty_surface_mouse_button(
                surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else {
            return super.rightMouseDown(with: event)
        }
    }
    public override func rightMouseUp(with event: NSEvent) {
        guard let surface,
            ghostty_surface_mouse_button(
                surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else {
            return super.rightMouseUp(with: event)
        }
    }
    public override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, Self.mods(event.modifierFlags))
    }
    public override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, Self.mods(event.modifierFlags))
    }
    public override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mouseMods(event.modifierFlags))
        scheduleHover(point, buttons: NSEvent.pressedMouseButtons)
    }

    /// Half a second at rest on a word asks the app whether it's worth a preview; moving off it closes that.
    private func scheduleHover(_ point: NSPoint, buttons: Int) {
        hoverTimer?.invalidate()
        if let rect = hovered, !rect.insetBy(dx: -2, dy: -2).contains(point) { endHover() }
        guard buttons == 0, onHoverWord != nil, hovered == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let hit = self.word(at: point) else { return }
                self.hovered = hit.rect
                self.onHoverWord?(hit.texts, hit.rect)
            }
        }
    }
    private func endHover() {
        hoverTimer?.invalidate()
        guard hovered != nil else { return }
        hovered = nil
        onHoverWord?([], .zero)
    }

    /// The run of characters under `point` up to blanks and brackets, with its parts on the rows it wraps onto — so
    /// "App.swift:12:5" stays whole (Ghostty's own words stop at ":"), and so does a path Claude Code broke in two.
    /// `texts`: the joined word first, then the row's own part (see `TerminalCopy.wrappedWord`); `rect`: that part.
    public func word(at point: NSPoint) -> (texts: [String], rect: NSRect)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface), scale = window?.backingScaleFactor ?? 2
        let cw = Double(size.cell_width_px) / scale, ch = Double(size.cell_height_px) / scale
        guard cw > 0, ch > 0, size.columns > 0 else { return nil }
        let padX = Self.padX, padY = Self.padY
        let col = Int((point.x - padX) / cw), row = Int((bounds.height - point.y - padY) / ch)
        guard row >= 0, row < Int(size.rows), col >= 0, col < Int(size.columns) else { return nil }
        let rowText = { (index: Int) -> String? in
            guard index >= 0, index < Int(size.rows) else { return nil }
            var text = ghostty_text_s()
            let left = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(index))
            let right = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(size.columns - 1),
                y: UInt32(index))
            let sel = ghostty_selection_s(top_left: left, bottom_right: right, rectangle: false)
            guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
            defer { ghostty_surface_free_text(surface, &text) }
            return String(cString: text.text)
        }
        guard let wrapped = TerminalCopy.wrappedWord(rows: rowText, row: row, at: col, columns: Int(size.columns))
        else {
            return nil
        }
        let rect = NSRect(
            x: padX + Double(wrapped.start) * cw, y: bounds.height - padY - Double(row + 1) * ch,
            width: Double(wrapped.width) * cw,
            height: ch)
        return (wrapped.texts, rect)
    }
    public override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    public override func mouseExited(with event: NSEvent) {
        endHover()
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }
    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var deltaX = event.scrollingDeltaX, deltaY = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            deltaX *= 2
            deltaY *= 2
        }
        let phases: [(NSEvent.Phase, Int32)] = [
            (.began, 1), (.stationary, 2), (.changed, 3), (.ended, 4), (.cancelled, 5), (.mayBegin, 6)
        ]
        let momentum = phases.first { $0.0 == event.momentumPhase }?.1 ?? 0
        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, (precise ? 1 : 0) | (momentum << 1))
    }
    public override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: keyboard (ported from Ghostty's SurfaceView)

    private func keyEvent(
        _ event: NSEvent, _ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil
    )
        -> ghostty_input_key_s
    {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        key.mods = Self.mods(event.modifierFlags)
        key.consumed_mods = Self.mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
            let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
        {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// Control characters are encoded by Ghostty itself; function keys (PUA) carry no text.
    private static func characters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return chars
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil, text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var key = keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing
        if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20 || text.count > 1 {
            return text.withCString {
                key.text = $0
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    private func committedText(_ text: String) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString {
            key.text = $0
            _ = ghostty_surface_key(surface, key)
        }
    }

    public override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        watchEcho()
        if window?.isKeyWindow == true { setVisible(true) }
        // Option-as-alt and friends: let Ghostty say which modifiers take part in translating to text.
        let tm = ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags))
        var translationMods = event.modifierFlags
        let bits: [(NSEvent.ModifierFlags, ghostty_input_mods_e)] = [
            (.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL),
            (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER)
        ]
        for (flag, bit) in bits {
            if tm.rawValue & bit.rawValue != 0 { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent =
            translationMods == event.modifierFlags
            ? event
            : (NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat,
                keyCode: event.keyCode) ?? event)
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
                if markedBefore {
                    committedText(text)
                } else {
                    keyAction(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else {
            if composing, let chars = event.characters, chars.count == 1,
                (chars.unicodeScalars.first?.value ?? 0x20) < 0x20
            {
                return
            }
            keyAction(
                action, event: event, translationEvent: translationEvent, text: Self.characters(translationEvent),
                composing: composing)
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
        var key = keyEvent(event, pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        key.mods = mouseMods(event.modifierFlags)   // ⌘ lights up the link under a resting pointer too (see linkMods)
        _ = ghostty_surface_key(surface, key)
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

    /// ⌘-keys: Ghostty's own bindings (copy, paste, scrolling) go to the terminal; everything else to the menus.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }
        var key = keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString {
            key.text = $0
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }
        // Control-Return and Control-/ would otherwise be eaten by AppKit.
        if event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command),
            ["\r", "/"].contains(event.charactersIgnoringModifiers ?? "")
        {
            keyDown(with: event)
            return true
        }
        return false
    }

    // MARK: NSTextInputClient

    public func hasMarkedText() -> Bool { markedText.length > 0 }
    public func markedRange() -> NSRange {
        markedText.length > 0
            ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let text = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: text)
        } else if let text = string as? String {
            markedText = NSMutableAttributedString(string: text)
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }
    public func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    { nil }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let rect = NSRect(x: x, y: bounds.height - y, width: 0, height: max(h, cellSize.height))
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }
    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        if !chars.isEmpty { committedText(chars) }
    }
    public override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let preedit = markedText.string
            preedit.withCString { ghostty_surface_preedit(surface, $0, UInt(preedit.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
