import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The ⌃Tab switcher, like ⌘Tab for apps. Hold ⌃ and press Tab to walk the screens you used last (⇧ goes back, ↑↓ and
/// the pointer work too, and 1–9 picks a row at once). Let go or click to switch, or press Esc to stay. A quick ⌃Tab
/// flips to the previous screen without showing the switcher. The screen you're on is the first row, dimmed, so the
/// next row is where you were before. The rows look like the sidebar's: the status, the project's icon, the name, and
/// one line of what's there (what the agent says, or a server's load). Servers' pages are screens too.
@MainActor
final class WorkspaceSwitcher {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    private var panel: NSPanel?
    private var monitor: Any?
    private var resigned: NSObjectProtocol?
    /// Workspace ids and server pages ("host:<name>"), in the order `RecentScreens` gives them.
    private var items: [String] = []
    private var index = 0
    private var rows: [NSView] = []
    private var pointerFrom: NSPoint?
    var isOpen: Bool { panel != nil }
    /// The key hints under the list, shown the first few times the switcher opens on this Mac.
    private static let hintsKey = "switcherHintsShown"

    /// Opens the switcher from the menu's ⌃Tab / ⌃⇧Tab. While the switcher is open its key monitor does the stepping,
    /// because the menu, which still gets the key, would step a second time.
    func step(_ by: Int) {
        guard panel == nil else { return }
        // ⌃⇧Tab can reach ⌃Tab's item (a menu matches Tab with ⇧ too), and the command runs after the key's event, so
        // whether ⇧ is still held says which way to go.
        let by = NSEvent.modifierFlags.contains(.shift) ? -1 : by
        let first = open()
        guard items.count > first else { return close(beep: true) }
        index = by > 0 ? first : items.count - 1   // ⌃Tab lands on where you were before, ⌃⇧Tab on the last row
        highlight()
        if !NSEvent.modifierFlags.contains(.control) { commit() }   // ⌃ already let go, so this is a quick flip
    }

    /// Picks row `number` when 1–9 is pressed while the switcher is open (⌃1–9 too, when the menu gets the key first).
    func pick(_ number: Int) {
        guard items.indices.contains(number) else { return NSSound.beep() }
        index = number
        commit()
    }

    private func move(_ by: Int) {
        guard !items.isEmpty else { return }
        index = (index + by + items.count) % items.count
        highlight()
    }

    /// Lists the screens and puts the panel up. Returns the first row that isn't the screen you're on.
    private func open() -> Int {
        let model = app, wb = app.workbench
        let current = wb.page ?? wb.workspaceId
        let workspaces = wb.workspacesInOrder
        let servers = app.extensions.all.servers == nil ? [] : app.remoteHosts.map(TabURI.server)
        // Screens not shown since Kelp started keeping the order are sorted by when their agents last did something,
        // or else by when they were made.
        let stirred = workspaces.map { worktree in
            (
                id: worktree.id,
                at: model.sessions.filter { $0.worktreeId == worktree.id }.map { $0.statusAt ?? $0.createdAt }.max()
                    ?? worktree.createdAt
            )
        }
        items = RecentScreens.order(
            current: current, recent: wb.recentWorkspaces, stirred: stirred,
            live: Set(workspaces.map(\.id) + servers))
        let first = items.first == current ? 1 : 0
        guard items.count > first, let window = app.workbench.mainWindow else { return first }
        pointerFrom = NSEvent.mouseLocation
        rows = items.enumerated().map { offset, id in row(id, number: offset, here: offset == 0 && first == 1) }
        let card = SwitcherCard(rows: rows, hint: Self.hint(), maxHeight: max(window.frame.height - 80, 160))
        let floating = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        floating.isOpaque = false
        floating.backgroundColor = .clear
        floating.hasShadow = true
        floating.level = .popUpMenu
        floating.contentView = card
        card.layoutSubtreeIfNeeded()
        floating.setFrame(Self.frame(card.fittingSize, over: window), display: true)
        panel = floating
        // The panel shows once ⌃ is held a moment, as with ⌘Tab, so a quick ⌃Tab flips without the panel flashing up.
        _ = Task { [weak self] in
            try await Task.sleep(for: .seconds(Motion.fast))
            guard self?.panel === floating else { return }
            Self.comeIn(floating, over: window)
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: Self.hintsKey) + 1, forKey: Self.hintsKey)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown]) {
            [weak self] event in self?.handle(event) ?? event
        }
        // After ⌘Tab away with ⌃ held, letting go of ⌃ never reaches Kelp, and the panel would keep every key.
        resigned = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }   // queue: .main
        }
        return first
    }

    /// Brings the panel on screen the way Quick Open comes: faint and a little high, then down into place.
    private static func comeIn(_ floating: NSPanel, over window: NSWindow) {
        let end = floating.frame
        guard !Motion.reduced else { return window.addChildWindow(floating, ordered: .above) }
        floating.setFrame(end.offsetBy(dx: 0, dy: Metrics.gapWide), display: false)
        floating.alphaValue = 0
        window.addChildWindow(floating, ordered: .above)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.base
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            floating.animator().setFrame(end, display: true)
            floating.animator().alphaValue = 1
        }
    }

    /// Takes the panel away a little quicker than it came. The switch itself happens at once, without waiting for this.
    private static func goAway(_ shown: NSPanel) {
        guard shown.isVisible, !Motion.reduced else {
            shown.parent?.removeChildWindow(shown)
            return shown.orderOut(nil)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shown.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {   // AppKit runs the completion handler on the main thread
                shown.parent?.removeChildWindow(shown)
                shown.orderOut(nil)
            }
        }
    }

    /// The panel's frame: over the window's middle, a little high, and kept on screen when the window is partly off it.
    private static func frame(_ size: NSSize, over window: NSWindow) -> NSRect {
        let windowFrame = window.frame
        var frame = NSRect(
            x: windowFrame.midX - size.width / 2, y: windowFrame.midY - size.height / 2 + windowFrame.height * 0.1,
            width: size.width, height: size.height)
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        return frame
    }

    /// The key hints, for the first five times the switcher shows. After that the hand knows them.
    private static func hint() -> String? {
        UserDefaults.standard.integer(forKey: hintsKey) >= 5
            ? nil : String(localized: "⇥ next · ⇧⇥ back · 1–9 go there · esc stay")
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            if !event.modifierFlags.contains(.control) { commit() }
            return event
        }
        if event.type != .keyDown { return mouse(event) }
        if let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number) {
            pick(number)
            return nil
        }
        switch event.keyCode {
        case 48: move(event.modifierFlags.contains(.shift) ? -1 : 1)   // Tab
        case 125: move(1)   // ↓
        case 126: move(-1)   // ↑
        case 36, 76: commit()
        case 53: close()   // Esc
        default: break
        }
        return nil   // while the switcher is open, keys belong to it
    }

    /// Pointing at a row selects it, and a click opens it. A click outside closes the switcher, as Esc does, and goes
    /// on to where it was aimed.
    private func mouse(_ event: NSEvent) -> NSEvent? {
        guard let shown = panel, event.window === shown else {
            if event.type == .leftMouseDown { close() }
            return event
        }
        // A move picks a row only once it's a real move, because the panel opens under the pointer and brushing the
        // trackpad shouldn't take the pick.
        if event.type == .mouseMoved, let from = pointerFrom {
            guard hypot(NSEvent.mouseLocation.x - from.x, NSEvent.mouseLocation.y - from.y) > 10 else { return nil }
            pointerFrom = nil
        }
        guard let hit = rows.firstIndex(where: { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) })
        else {
            return nil
        }
        if event.type == .leftMouseDown {
            index = hit
            commit()
        } else if hit != index {
            index = hit
            highlight()
        }
        return nil
    }

    private func commit() {
        let pick = items.indices.contains(index) ? items[index] : nil
        close()
        guard let pick else { return }
        if TabURI.scheme(pick) == "host" {
            app.workbench.openServer(TabURI.body(pick))
        } else {
            app.workbench.show(workspace: pick)
        }
    }

    private func close(beep: Bool = false) {
        if beep { NSSound.beep() }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resigned { NotificationCenter.default.removeObserver(resigned) }
        resigned = nil
        if let shown = panel { Self.goAway(shown) }
        panel = nil
        rows = []
        items = []
    }

    private func highlight() {
        if rows.indices.contains(index) {
            let row = rows[index]
            row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -8))   // scrolls into view, with the list's margin
            // VoiceOver announces the row, because the panel never takes focus, so moving through it would go unheard.
            NSAccessibility.post(
                element: row, notification: .announcementRequested,
                userInfo: [
                    .announcement: row.accessibilityLabel() ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue
                ])
        }
        // The selection is grey, as in ⌘Tab, so the status marks and the colours of the changes stay readable on it.
        // It fades instead of switching.
        for (offset, row) in rows.enumerated() { row.fadeBackground(to: offset == index ? .fillSelected : nil) }
    }

    /// The row for one screen: a server's page or a workspace.
    private func row(_ id: String, number: Int, here: Bool) -> NSView {
        let parts =
            TabURI.scheme(id) == "host"
            ? SwitcherRow.server(TabURI.body(id), app: app)
            : app.worktree(id).map { SwitcherRow.workspace($0, app: app) }
        return (parts ?? SwitcherRow(name: NSAttributedString(string: id))).view(number: number, here: here)
    }
}
