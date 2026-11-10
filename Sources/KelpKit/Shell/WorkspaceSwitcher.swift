import AppKit
import Core
import DesignKit
import WorkbenchKit

/// ⌃Tab, like ⌘Tab for apps: hold ⌃ and press Tab to walk the screens you used last (⇧ goes back, ↑↓ and the pointer
/// too, 1–9 picks a row at once), let go or click to switch; Esc stays. A quick ⌃Tab flips to the previous screen
/// without showing it. The screen you're on is the first row, dimmed, so the next one is where you were before. Its
/// rows are the sidebar's: the status, the project's icon, the name, and one line of what's there (what the agent says,
/// or a server's load). Servers' pages are screens too.
@MainActor
final class WorkspaceSwitcher {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    private var panel: NSPanel?
    private var monitor: Any?
    private var resigned: NSObjectProtocol?
    /// Workspace ids and servers' pages ("host:<name>"), as `RecentScreens` orders them.
    private var items: [String] = []
    private var index = 0
    private var rows: [NSView] = []
    private var pointerFrom: NSPoint?
    var isOpen: Bool { panel != nil }
    /// The keys under the list, for the first few times it's opened on this Mac.
    private static let hintsKey = "switcherHintsShown"

    /// The menu's ⌃Tab / ⌃⇧Tab: opens it. While it's open its key monitor steps, and the menu, which still gets the
    /// key, would step a second time.
    func step(_ by: Int) {
        guard panel == nil else { return }
        // ⌃⇧Tab can reach ⌃Tab's item (a menu matches Tab with ⇧ too), and the command runs after the key's event:
        // ⇧ still held says which way.
        let by = NSEvent.modifierFlags.contains(.shift) ? -1 : by
        let first = open()
        guard items.count > first else { return close(beep: true) }
        index = by > 0 ? first : items.count - 1   // ⌃Tab lands on where you were before, ⌃⇧Tab on the last row
        highlight()
        if !NSEvent.modifierFlags.contains(.control) { commit() }   // already let go: a quick flip
    }

    /// 1–9 while it's open (⌃1–9 too, when the menu gets the key first): that row.
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

    /// Lists the screens and puts the panel up; the first row that isn't the one on screen.
    private func open() -> Int {
        let model = app, wb = app.workbench
        let current = wb.page ?? wb.workspaceId
        let workspaces = wb.workspacesInOrder
        let servers = app.extensions.all.servers == nil ? [] : app.remoteHosts.map(TabURI.server)
        // Ones not on screen since Kelp started keeping the order: by their agents' last stir, else when they were
        // made.
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
        // On screen once ⌃ is held a moment, as ⌘Tab: a quick ⌃Tab flips without the panel flashing up.
        _ = Task { [weak self] in
            try await Task.sleep(for: .milliseconds(120))
            guard self?.panel === floating else { return }
            window.addChildWindow(floating, ordered: .above)
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: Self.hintsKey) + 1, forKey: Self.hintsKey)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown]) {
            [weak self] event in self?.handle(event) ?? event
        }
        // ⌘Tab away with ⌃ held: letting go of ⌃ never reaches Kelp, and the panel would keep every key.
        resigned = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }   // queue: .main
        }
        return first
    }

    /// Over the window's middle, a little high, and on screen when the window is partly off it.
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

    /// The keys, the first five times it shows: after that the hand knows them.
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
        return nil   // while it's open, keys belong to it
    }

    /// Pointing at a row selects it, a click opens it; a click outside closes, as Esc, and goes on where it was meant.
    private func mouse(_ event: NSEvent) -> NSEvent? {
        guard let shown = panel, event.window === shown else {
            if event.type == .leftMouseDown { close() }
            return event
        }
        // A move picks once it's a real one: the panel opens under the pointer, and brushing the trackpad shouldn't
        // take the pick.
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
        if let shown = panel {
            shown.parent?.removeChildWindow(shown)
            shown.orderOut(nil)
        }
        panel = nil
        rows = []
        items = []
    }

    private func highlight() {
        if rows.indices.contains(index) {
            let row = rows[index]
            row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -8))   // in view, with the list's margin
            // VoiceOver says the row: the panel never takes focus, so moving through it would go unheard.
            NSAccessibility.post(
                element: row, notification: .announcementRequested,
                userInfo: [
                    .announcement: row.accessibilityLabel() ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue
                ])
        }
        // Grey, as ⌘Tab's: the status marks and the changes' colours stay readable on it. Faded, not switched.
        for (offset, row) in rows.enumerated() { row.fadeBackground(to: offset == index ? .fillSelected : nil) }
    }

    /// One screen's row: a server's page or a workspace's.
    private func row(_ id: String, number: Int, here: Bool) -> NSView {
        let parts =
            TabURI.scheme(id) == "host"
            ? SwitcherRow.server(TabURI.body(id), app: app)
            : app.worktree(id).map { SwitcherRow.workspace($0, app: app) }
        return (parts ?? SwitcherRow(name: NSAttributedString(string: id))).view(number: number, here: here)
    }
}
