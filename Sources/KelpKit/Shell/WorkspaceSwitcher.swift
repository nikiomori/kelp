import AppKit
import Core
import DesignKit

/// ⌃Tab, like ⌘Tab for apps: hold ⌃ and press Tab to walk the workspaces you used last (⇧ goes back, ↑↓ and the pointer
/// too), let go or click to switch; Esc stays. A quick ⌃Tab flips to the previous workspace without showing it. The one on
/// screen isn't listed, so the first row is where you were before. Each row says what's there: project and branch,
/// changes not committed, the pull request, and the agent that matters most (what it's doing and its last words).
@MainActor
final class WorkspaceSwitcher {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    private var panel: NSPanel?
    private var monitor: Any?
    private var resigned: NSObjectProtocol?
    private var items: [Worktree] = []
    private var index = 0
    private var rows: [NSView] = []
    private var pointerFrom: NSPoint?

    /// The menu's ⌃Tab / ⌃⇧Tab: opens it. While it's open its key monitor steps, and the menu, which still gets the key,
    /// would step a second time.
    func step(_ by: Int) {
        guard panel == nil else { return }
        open()
        index = by > 0 ? -1 : 0   // ⌃Tab lands on the first row, ⌃⇧Tab on the last
        move(by)
    }

    private func move(_ by: Int) {
        guard !items.isEmpty else { return }
        index = (index + by + items.count) % items.count
        highlight()
        if !NSEvent.modifierFlags.contains(.control) { commit() }   // already let go: a quick flip
    }

    private func open() {
        let m = app, wb = app.workbench
        let live = app.workbench.workspacesInOrder
        // Ones not on screen since Kelp started keeping the order: by their agents' last stir, else when they were made.
        let stirred = live.map { w in (w.id, m.sessions.filter { $0.worktreeId == w.id }.map { $0.statusAt ?? $0.createdAt }.max() ?? w.createdAt) }
        var order: [String] = []
        for id in wb.recentWorkspaces + stirred.sorted { $0.1 > $1.1 }.map(\.0)
        where id != wb.workspaceId && !order.contains(id) && live.contains(where: { $0.id == id }) {
            order.append(id)
        }
        items = order.compactMap(m.worktree)
        guard !items.isEmpty, let window = app.workbench.window?.window else {
            items = []
            NSSound.beep()
            return
        }
        pointerFrom = NSEvent.mouseLocation

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 2
        list.alignment = .leading
        list.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        rows = items.map { row($0) }
        rows.forEach { list.addArrangedSubview($0); $0.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true }
        list.widthAnchor.constraint(equalToConstant: 520).isActive = true
        let doc = FlippedView()
        doc.pin(list)
        // The pointer selects (its moves reach the monitor even though the panel never becomes key).
        doc.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: doc))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay   // a legacy scroller would take the rows' right edge
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        // At most 440 pt (eight two-line rows) and never past the window; more scroll.
        NSLayoutConstraint.activate([doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                                     doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                                     scroll.widthAnchor.constraint(equalToConstant: 520),
                                     scroll.heightAnchor.constraint(equalToConstant: min(list.fittingSize.height, 440, max(window.frame.height - 80, 160)))])
        let fx = NSVisualEffectView()
        fx.material = .popover   // as Quick Open's
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = Metrics.radiusXL
        fx.layer?.cornerCurve = .continuous
        fx.layer?.borderWidth = 1   // an edge, as menus have, so it holds against a window of the same grey
        fx.effectiveAppearance.performAsCurrentDrawingAppearance { fx.layer?.borderColor = NSColor.separatorColor.cgColor }
        fx.pin(scroll)
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.contentView = fx
        fx.layoutSubtreeIfNeeded()
        let size = fx.fittingSize, f = window.frame
        var frame = NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.1, width: size.width, height: size.height)
        if let s = window.screen?.visibleFrame {   // a window partly off screen keeps it on screen
            frame.origin.x = min(max(frame.minX, s.minX), s.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, s.minY), s.maxY - frame.height)
        }
        p.setFrame(frame, display: true)
        panel = p
        // On screen once ⌃ is held a moment, as ⌘Tab: a quick ⌃Tab flips without the panel flashing up.
        Task { [weak self] in
            try await Task.sleep(for: .milliseconds(120))
            if self?.panel === p { window.addChildWindow(p, ordered: .above) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown]) { [weak self] e in self?.handle(e) ?? e }
        // ⌘Tab away with ⌃ held: letting go of ⌃ never reaches Kelp, and the panel would keep every key.
        resigned = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }   // queue: .main
        }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        if e.type == .flagsChanged { if !e.modifierFlags.contains(.control) { commit() }; return e }
        if e.type != .keyDown { return mouse(e) }
        switch e.keyCode {
        case 48: move(e.modifierFlags.contains(.shift) ? -1 : 1)   // Tab
        case 125: move(1)    // ↓
        case 126: move(-1)   // ↑
        case 36, 76: commit()
        case 53: close()     // Esc
        default: break
        }
        return nil   // while it's open, keys belong to it
    }

    /// Pointing at a row selects it, a click opens it; a click outside closes, as Esc, and goes on where it was meant.
    private func mouse(_ e: NSEvent) -> NSEvent? {
        guard let p = panel, e.window === p else {
            if e.type == .leftMouseDown { close() }
            return e
        }
        // A move picks once it's a real one: the panel opens under the pointer, and brushing the trackpad shouldn't take the pick.
        if e.type == .mouseMoved, let from = pointerFrom {
            guard hypot(NSEvent.mouseLocation.x - from.x, NSEvent.mouseLocation.y - from.y) > 10 else { return nil }
            pointerFrom = nil
        }
        guard let i = rows.firstIndex(where: { $0.bounds.contains($0.convert(e.locationInWindow, from: nil)) }) else { return nil }
        if e.type == .leftMouseDown {
            index = i
            commit()
        } else if i != index {
            index = i
            highlight()
        }
        return nil
    }

    private func commit() {
        let pick = items.indices.contains(index) ? items[index].id : nil
        close()
        if let pick { app.workbench.show(workspace: pick) }
    }

    private func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resigned { NotificationCenter.default.removeObserver(resigned) }
        resigned = nil
        if let p = panel { p.parent?.removeChildWindow(p); p.orderOut(nil) }
        panel = nil; rows = []
    }

    private func highlight() {
        if rows.indices.contains(index) {
            let r = rows[index]
            r.scrollToVisible(r.bounds.insetBy(dx: 0, dy: -8))   // in view, with the list's margin
            // VoiceOver says the row: the panel never takes focus, so moving through it would go unheard.
            NSAccessibility.post(element: r, notification: .announcementRequested,
                                 userInfo: [.announcement: r.accessibilityLabel() ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        // Grey, as ⌘Tab's: the status marks and the changes' colours stay readable on it. Faded, not switched.
        for (i, r) in rows.enumerated() { r.fadeBackground(to: i == index ? .fillSelected : nil) }
    }

    /// Status | project | name, place, badges, when — and the agent the mark is for on a second line, when there is one.
    private func row(_ w: Worktree) -> NSView {
        let m = app
        let agents = m.sessions.filter { $0.worktreeId == w.id && $0.agent != "shell" && $0.status != .exited }
        let top = AgentStatus.mostUrgent(agents.map(SidebarCell.shownStatus))
        let lead = agents.filter { SidebarCell.shownStatus($0) == top }.max { ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt) }
        let mark = StatusMark(size: 14)
        mark.status = top
        mark.unread = agents.contains { SidebarCell.shownStatus($0) == top && $0.unread }
        mark.announces = false   // the row's label says the state

        let icon = NSImageView(image: .symbol("folder"))
        if let r = m.repo(w.repoId) { ProjectIcon.show(r.path, in: icon, app: m) }
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true; icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let name = label(w.displayName, .ui(13, weight: .semibold))
        let repo = m.repo(w.repoId)
        // The branch even for the project's own folder: two projects' "Workspace 1" tell apart.
        let place = label([m.projectName(repo?.id), w.branch == w.displayName ? nil : w.branch].compactMap { $0 }.joined(separator: " · "),
                          .ui(12), secondary: true)
        let folder = app.rowBadges.folder(of: w.id)
        let changes = label("", .uiDigits(11)), pr = label("", .uiDigits(11))
        if let c = folder.flatMap({ RowBadges.changes(app.rowBadges.stats[$0.id], compact: true) }) {
            changes.attributedStringValue = c
        } else {
            changes.isHidden = true
        }
        if let p = folder.flatMap({ RowBadges.pr(app.rowBadges.prs[$0.id]) }) { pr.attributedStringValue = p.0 } else { pr.isHidden = true }
        let when = label(shortAgo(lead.map { $0.statusAt ?? $0.createdAt }), .uiDigits(11), secondary: true)
        when.alignment = .right
        when.setContentCompressionResistancePriority(.required, for: .horizontal)   // a long name truncates, not the time
        when.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true   // the times line up
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let ci = CIMark()
        ci.state = folder.flatMap { app.rowBadges.sidebarCI($0.id) }
        let top1 = NSStackView(views: [name, place, gap, changes, pr, ci, when])
        top1.distribution = .fill   // the gap takes the slack: the badges sit at the right edge
        top1.spacing = 6
        for v in [changes, pr, ci] { top1.setCustomSpacing(8, after: v) }
        top1.alignment = .firstBaseline
        top1.detachesHiddenViews = true

        // "Claude Code · Needs your input — Which test runner?  +1 more": the agent the mark is for.
        let others = agents.count - 1
        let said = lead.map { s in
            [app.catalog.displayName(s) + " · " + s.statusWords, s.summary].filter { !$0.isEmpty }.joined(separator: " — ")
                + (others > 0 ? "  " + String(localized: "+\(others) more") : "")
        }
        let detail = label(said ?? "", .ui(12), secondary: true)
        detail.isHidden = said == nil   // no agents: one line
        let text = NSStackView(views: [top1, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.detachesHiddenViews = true
        top1.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true

        text.setContentHuggingPriority(.init(1), for: .horizontal)
        let slot = NSView()   // no agents hides the mark; its column stays, so the names line up
        slot.pin(mark)
        let r = NSStackView(views: [slot, icon, text])
        r.distribution = .fill
        r.spacing = 10
        r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        r.wantsLayer = true; r.layer?.cornerRadius = 8
        r.setAccessibilityElement(true)
        r.setAccessibilityLabel([w.displayName, place.stringValue, said, when.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        return r
    }

    private func label(_ s: String, _ font: NSFont, secondary: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = secondary ? .secondaryLabelColor : .labelColor
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(secondary ? .defaultLow : .init(400), for: .horizontal)
        return t
    }
}
