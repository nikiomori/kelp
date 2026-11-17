import AppKit
import DesignKit

/// A place shown in a window of its own (from its row's Open in Own Window): a group's editor area, or a server's or
/// machine's page, in a card under the title and nothing else; the sidebar and the inspector stay in the main window.
/// The window opens where it was last (`name`), otherwise on a display the main window isn't on. What its close button
/// does is up to its owner (`closed`): a group goes back to the main window, and a page closes.
@MainActor
final class OwnWindow: NSWindowController, NSWindowDelegate {
    private let card = Card()
    private let surface: DropRoot
    private let becameKey: () -> Void
    /// What its close button does, and ⌘W while it has the keys.
    let closed: () -> Void

    init(
        app: AppModel, name: String, content: NSView, beside main: NSWindow?, title: @escaping @MainActor () -> String?,
        becameKey: @escaping () -> Void = {}, closed: @escaping () -> Void
    ) {
        self.becameKey = becameKey
        self.closed = closed
        surface = DropRoot(app: app)
        let made = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        super.init(window: made)
        made.titlebarAppearsTransparent = true
        made.titlebarSeparatorStyle = .none
        made.isReleasedWhenClosed = false
        made.delegate = self
        made.contentMinSize = NSSize(width: 480, height: 320)
        let root = NSViewController()
        surface.frame = NSRect(origin: .zero, size: Self.size)   // the window takes its content's size
        root.view = surface
        surface.pin(card, inset: NSEdgeInsets(top: WindowBar.height, left: Card.gap, bottom: Card.gap, right: Card.gap))
        card.identifier = Banner.anchor   // banners sit in its corner while this window is in front
        card.pin(content)
        made.contentViewController = root
        if !made.setFrameUsingName(name) {
            let screens = NSScreen.screens.map(\.visibleFrame)
            made.setFrame(
                Self.frame(Self.size, screens: screens, avoiding: main?.screen?.visibleFrame), display: false)
        }
        made.setFrameAutosaveName(name)   // Limit: a closed group's saved frame stays in the defaults
        track(owner: self) {
            app.themes.look
        } changed: { [weak self] look in
            self?.surface.show(look)
            self?.card.look = look
        }
        track(owner: self, title) { [weak self] in
            self?.window?.title = $0 ?? String(localized: "Kelp")
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private static let size = NSSize(width: 1100, height: 760)

    /// Where a window of `size` first opens: centred on the largest display other than the main window's, else on the
    /// main window's display (or the first one), offset so it doesn't exactly cover the main window.
    static func frame(_ size: NSSize, screens: [NSRect], avoiding: NSRect?) -> NSRect {
        let others = screens.filter { $0 != avoiding }
        let pick = others.max { $0.width * $0.height < $1.width * $1.height }
        guard let screen = pick ?? avoiding ?? screens.first else { return NSRect(origin: .zero, size: size) }
        let fit = NSSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
        let shift: CGFloat = pick == nil ? 40 : 0
        return NSRect(
            x: min(screen.midX - fit.width / 2 + shift, screen.maxX - fit.width),
            y: max(screen.midY - fit.height / 2 - shift, screen.minY), width: fit.width, height: fit.height)
    }

    /// It has the keys, as AppKit last said: kept from its calls (a test's window never gets them from the system).
    private(set) var hasKeys = false
    func windowDidBecomeKey(_ notification: Notification) {
        hasKeys = true
        becameKey()
    }
    func windowDidResignKey(_ notification: Notification) { hasKeys = false }

    /// The close button: its owner closes the window, once what's in it is put away.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closed()
        return false
    }
}
