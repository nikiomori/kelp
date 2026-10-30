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

/// A surface's way to its view (its userdata): weak, as a surface being retired has outlived the view.
@MainActor
final class SurfaceLink {
    weak var view: GhosttyTerminalView?
    /// It called back since this was last cleared (`GhosttyRuntime.retire`).
    var heard = false
}

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

    /// Surfaces whose view is gone and which aren't freed yet.
    private(set) var retiring = 0

    /// Frees a surface whose view is gone, once its program has ended and nothing more comes from it. `ghostty_surface_free`
    /// waits for the surface's threads, and its reader first goes through all it has read (megabytes), posting to the app's
    /// mailbox (64 messages for all surfaces, one per title a program sets, thousands in a replayed history), which only a
    /// tick on this thread empties: freed at once, with programs printing, the app stopped for good. So the program ends
    /// first and the reader finishes with the ticks going on; the exit alone says little, it can come before or after that.
    /// Limit: one that ignores its hangup and keeps printing stays until the app quits, rather than stopping it.
    func retire(_ surface: ghostty_surface_t, _ link: SurfaceLink) {
        retiring += 1
        Task {
            var quiet = 0   // looks in a row with nothing from it
            while !(ghostty_surface_process_exited(surface) && quiet > 0), quiet < 40 {
                Self.hangUp(surface)
                link.heard = false
                try await Task.sleep(for: .milliseconds(50))   // never cancelled: nothing holds this task
                quiet = link.heard ? 0 : quiet + 1
            }
            ghostty_surface_free(surface)
            retiring -= 1
        }
    }

    /// As Ghostty stops a program: to its process group, as the `login` above it is root's and ends with it.
    private static func hangUp(_ surface: ghostty_surface_t) {
        let group = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
        if group > 1 { killpg(group, SIGHUP) }
    }

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
        rt.read_clipboard_cb = { ud, _, state, mimes, count, list in
            MainActor.assumeIsolated {
                GhosttyTerminalView.from(ud)?.readClipboard(state: state, mimes: mimes, count: count, list: list) ?? GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }
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
            if let s = String(bytes: UnsafeRawBufferPointer(start: p, count: Int(u.len)), encoding: .utf8), let url = URL(string: s) {
                if let h = view?.onOpenURL { h(url) } else { NSWorkspace.shared.open(url) }
            }
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
