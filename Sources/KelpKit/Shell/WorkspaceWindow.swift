import AppKit
import DesignKit

/// A group in a window of its own (its row's Open in Own Window): its editor area in a card under the title, nothing
/// else; the sidebar and the inspector stay in the main window and follow whichever window has the keys. It opens where
/// it was last, else on a display the main window isn't on. Its close button puts the group back in the main window.
@MainActor
final class WorkspaceWindow: NSWindowController, NSWindowDelegate {
    let workspaceId: String
    private let app: AppModel
    private let card = Card()
    private let surface: DropRoot

    init(app: AppModel, area: EditorArea, beside main: NSWindow?) {
        workspaceId = area.workspaceId
        self.app = app
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
        card.pin(area.view)
        made.contentViewController = root
        let name = "workspace." + workspaceId
        if !made.setFrameUsingName(name) {
            let screens = NSScreen.screens.map(\.visibleFrame)
            made.setFrame(
                Self.frame(Self.size, screens: screens, avoiding: main?.screen?.visibleFrame), display: false)
        }
        made.setFrameAutosaveName(name)   // Limit: a closed group's saved frame stays in the defaults
        let id = workspaceId
        track(owner: self) {
            app.themes.look
        } changed: { [weak self] look in
            self?.surface.show(look)
            self?.card.look = look
        }
        track(owner: self) {
            app.worktree(id).map { app.groupName($0) ?? app.projectName($0.repoId) ?? $0.displayName }
        } changed: { [weak self] in
            self?.window?.title = $0 ?? String(localized: "Kelp")
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private static let size = NSSize(width: 1100, height: 760)

    /// Where a window of `size` first opens: centred on the largest display other than the main window's, else on
    /// the main window's (or the first) display, offset so it doesn't hide the main window exactly.
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

    func windowDidBecomeKey(_ notification: Notification) { app.workbench.ownWindowBecameKey(workspaceId) }

    /// The close button: the group goes back to the main window, nothing in it closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        app.workbench.returnToMain(workspaceId)
        return false
    }
}
