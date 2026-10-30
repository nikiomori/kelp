import AppKit
import Core
import DesignKit
import WorkbenchKit

/// ⌘P: files, worktrees, agents, tabs, commands in one fuzzy list; "#123" finds a pull request. ⇧⌘P: commands only.
/// Empty, it lists the agents to get back to — those that need you first — on ⌘1–⌘6, in an order that holds still
/// while it's open. ⇧↩ opens the choice in a split. A setting with choices (Color Theme, File Icon Theme, on/off…) lists them
/// right here, the one in effect ticked; for looks, moving through them tries each on, ↩ keeps it, esc goes back.
@MainActor
package final class QuickOpen: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init() }

    struct Item {
        let kind: String
        let icon: String
        let title: String
        let detail: String
        let action: () -> Void
        /// ⇧↩: the same thing in a split to the right (files, agents, tabs).
        var split: (() -> Void)?
        /// An agent's: its state where the icon goes, as on its tab.
        var session: Session?
        /// A setting with choices: its value now, on the right; choosing it lists the choices here.
        var value: String?
        /// One of those choices: the value it sets, whether it's in effect, and its theme's colors.
        var choice: JSONValue?
        var checked = false
        var image: NSImage?
        /// A file's path, ready for fuzzy matching.
        var fuzzy: ProjectFiles.FuzzyPath?
        /// A command's shortcut, at the end of its title's line as in a menu.
        var key = ""
        /// Run from here lately: on top of ⇧⌘P's empty list, under Recently Used.
        var recent = false
    }
    /// A setting's choices on screen: the key, the value to go back to, whether moving tries them on, the query to return to.
    struct Choosing {
        let key: String
        let saved: JSONValue?
        let tries: Bool
        let query: String
    }
    var choosing: Choosing?
    /// A list row: a group's heading ("Files", "Agents"…) while searching, or an item.
    private enum Row {
        case heading(String), item(Item)
        var isItem: Bool { if case .item = self { true } else { false } }
    }
    private var rows: [Row] = []

    var panel: QuickPanel!
    /// What the empty field shows, made once per opening so rows don't move under the pointer.
    var recents: [Item] = []
    private var showingRecents = false
    var prSearch: Task<Void, Never>?
    var filesLoad: Task<Void, Never>?
    /// The typed query's matches being scored; the next keystroke cancels it.
    private var scoring: Task<Void, Never>?
    let field = PaletteField()
    private let table = PaletteTable()
    let keys = Keycaps()
    var all: [Item] = []
    var commandsOnly = false
    /// The title bar's Search pill, which the palettes grow out of.
    weak var anchor: NSView?
    /// The tmux sessions listed instead of the palette (`showTmux`); nil for the palette.
    var tmux: [Tmux.Session]?
    var tmuxLoad: Task<Void, Never>?

    package func show(commandsOnly: Bool) {
        if panel == nil { build() }
        self.commandsOnly = commandsOnly
        list(query: "")
        present()
    }

    /// Out of the title bar's Search pill (`anchor`), as if the pill widened into the field and the list dropped from it;
    /// without the pill on screen, under the window's top.
    func present() {
        panel.alphaValue = 1
        guard let w = anchor?.window ?? NSApp.mainWindow else { return show() }
        let size = panel.frame.size, f = w.frame
        guard let pill = anchor, pill.window === w, !pill.isHiddenOrHasHiddenAncestor else {
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 120))
            return show()
        }
        let p = w.convertToScreen(pill.convert(pill.bounds, to: nil))
        let x = min(max(p.midX - size.width / 2, f.minX + 8), f.maxX - size.width - 8)
        let end = NSRect(x: x, y: p.maxY + 6 - size.height, width: size.width, height: size.height)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { panel.setFrame(end, display: false); return show() }
        // From the pill's place and width, as tall as the field and a row, faint; to its full size in 0.2 s.
        panel.setFrame(NSRect(x: p.minX, y: p.maxY + 6 - 120, width: max(p.width, 200), height: 120), display: false)
        panel.alphaValue = 0
        show()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.base
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 1
        }
        func show() {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
        }
    }

    /// The palette's own list (not a setting's choices), with `query` typed.
    private func list(query: String) {
        stopChoosing()
        tmuxLoad?.cancel(); tmux = nil
        field.placeholderString = commandsOnly ? String(localized: "Run a command") : String(localized: "Search workspaces, agents, tabs, files and commands")
        let label = commandsOnly ? String(localized: "Commands") : String(localized: "Search")
        field.setAccessibilityLabel(label)
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.image = NSImage(systemSymbolName: commandsOnly ? "command" : "magnifyingglass",
                                                                             accessibilityDescription: label)
        // The keys it knows, under the list (they're not written anywhere else).
        keys.stringValue = commandsOnly ? String(localized: "↑↓ Select    ↩ Run    ⌫ Everything")
            : String(localized: "↑↓ Select    ↩ Open    ⇧↩ Open in a Split    > Commands    # Pull Requests")
        field.stringValue = query
        field.scope = commandsOnly ? String(localized: "Commands") : nil
        collect()
        filter()
    }

    /// A setting's choices in the list instead, the one in effect ticked and selected. Looks (Appearance) are tried on
    /// as the selection moves, so you see the theme before keeping it.
    func pick(_ section: SettingsSection, _ spec: SettingSpec) {
        let store = app.settings, now = store.value(spec.key)
        choosing = Choosing(key: spec.key, saved: store.values[spec.key], tries: section.id == "appearance", query: field.stringValue)
        all = choices(spec).map { v, name in
            let (note, image) = spec.key == "workbench.theme" ? self.themeLook(v.string ?? "") : ("", nil)
            return Item(kind: "Choice", icon: v.string == "ghostty" ? "terminal" : "", title: name, detail: note, action: { store.set(spec.key, v) },
                        choice: v, checked: v == now, image: image)
        }
        field.placeholderString = "\(loc(section.title)) › \(loc(spec.title))"
        keys.stringValue = choosing?.tries == true
            ? String(localized: "↑↓ Try On    ↩ Keep    esc Back")
            : String(localized: "↑↓ Select    ↩ Choose    esc Back")
        field.stringValue = ""
        filter()
    }

    /// Leaves a setting's choices with the value it had: what was tried on goes away.
    func stopChoosing() {
        if let c = choosing { app.settings.preview(c.key, c.saved) }
        choosing = nil
    }

    /// The selected choice, on screen while it's selected (looks only).
    private func tryOn() {
        guard let c = choosing, c.tries, rows.indices.contains(table.selectedRow), case .item(let it) = rows[table.selectedRow] else { return }
        app.settings.preview(c.key, it.choice)
    }

    func build() {
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .fullSizeContentView, .closable],
                           backing: .buffered, defer: false)
        panel.onNumber = { [weak self] n in self?.pickRecent(n) ?? false }
        panel.title = String(localized: "Open Quickly")   // hidden; the Window menu and VoiceOver read it
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true; panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        // Spotlight's ground: Liquid Glass on macOS 26, the popover material before. Its views go in `effect`.
        let effect = NSView()
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 16
            glass.contentView = effect
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.contentView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.state = .active
            material.pin(effect)
            panel.contentView = material
        }
        field.font = .ui(18)
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self; field.action = #selector(filterAction)
        let col = NSTableColumn(identifier: .init("i"))
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.backgroundColor = .clear
        table.target = self; table.doubleAction = #selector(activate)
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        let line = NSBox(); line.boxType = .separator
        let top = NSBox(); top.boxType = .separator   // under the field, which is the panel's top, not a box of its own
        for v in [field, top, sv, line, keys] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16), field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            top.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: effect.leadingAnchor), top.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            sv.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6), sv.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            sv.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6), sv.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -4),
            line.leadingAnchor.constraint(equalTo: effect.leadingAnchor), line.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -28),
            keys.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            keys.centerYAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14)
        ])
    }

    private func pickRecent(_ n: Int) -> Bool {
        guard showingRecents, recents.indices.contains(n - 1), recents[n - 1].kind != "Workspace" else { return false }
        panel.orderOut(nil); NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        recents[n - 1].action()
        return true
    }

    /// "#123" or "#login": the project's open pull requests (gh), opened in the browser tab.
    private func searchPullRequests(_ q: String) {
        let app = self.app
        prSearch?.cancel()
        guard let repo = app.worktree(app.workbench.workspaceId)?.repoId else { return }
        prSearch = Task { [weak self] in
            let prs = await app.call(GitHubPRs(repoId: repo, filter: "open")) ?? []   // gh missing or signed out: says so
            guard let self, !Task.isCancelled, field.stringValue == q else { return }
            let term = String(q.dropFirst()).lowercased()
            setRows(prs.filter { p in term.isEmpty || "\(p.number)".hasPrefix(term) || p.title.lowercased().contains(term) }.map { p in
                Item(kind: "Pull Request", icon: "arrow.triangle.pull", title: "#\(p.number) \(p.title)",
                     detail: "\(p.author) · \(p.headRefName)", action: { app.workbench.open(p.url) })
            }, grouped: false)
        }
    }

    /// A title matches when it contains the query, or each query word starts a word of the title.
    nonisolated static func wordScore(_ title: String, _ query: String) -> Int? {
        let t = title.lowercased(), q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        if t.hasPrefix(q) { return 100 }
        let words = t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 80 }
        if t.contains(q) { return 60 }
        let parts = q.split(separator: " ").map(String.init)
        return parts.count > 1 && parts.allSatisfy({ p in words.contains { $0.hasPrefix(p) } }) ? 40 : nil
    }

    /// An uppercase key equivalent means ⇧ too.
    static func shortcut(_ i: NSMenuItem) -> String {
        var m = KeySpec.Modifiers(i.keyEquivalentModifierMask)
        if i.keyEquivalent != i.keyEquivalent.lowercased() { m.insert(.shift) }
        return KeyBindings.display(KeySpec(key: i.keyEquivalent, mods: m))
    }

    @objc private func filterAction() { filter() }
    package func controlTextDidChange(_ obj: Notification) {
        // ">" first, as in VS Code: the commands, with what follows it.
        if !commandsOnly, choosing == nil, tmux == nil, field.stringValue.hasPrefix(">") {
            commandsOnly = true
            list(query: String(field.stringValue.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }
        filter()
    }

    func filter() {
        scoring?.cancel()
        let q = field.stringValue
        if let t = tmux { setRows(tmuxItems(t, q), grouped: false); return }
        let pool = commandsOnly && choosing == nil ? all.filter { $0.kind == "Command" || $0.kind == "Setting" } : all
        if !commandsOnly, choosing == nil, q.hasPrefix("#") {
            setRows([], grouped: false)
            searchPullRequests(q)
            return
        }
        if q.isEmpty {
            showingRecents = !commandsOnly && choosing == nil && !recents.isEmpty
            let used = commandsOnly && choosing == nil ? Self.recentlyUsed(pool) : []
            let ids = Set(used.map(Self.usedID))
            let rest = (commandsOnly ? pool : pool.filter { $0.kind != "File" }).filter { !ids.contains(Self.usedID($0)) }
            setRows(showingRecents ? recents : used + Array(rest.prefix(200)),
                    grouped: (!showingRecents && !commandsOnly && choosing == nil) || !used.isEmpty, heading: showingRecents ? "Recent" : nil)
        } else {
            showingRecents = false
            // Off the main thread: a big project's files take a while to score on every keystroke.
            let grouped = !commandsOnly && choosing == nil, keys = pool.map { Match(fuzzy: $0.fuzzy, title: $0.title, command: $0.kind == "Command") }
            scoring = Task { [weak self] in
                let best = await Task.detached { Self.best(keys, q) }.value
                guard let self, !Task.isCancelled else { return }
                setRows(best.map { pool[$0] }, grouped: grouped)
            }
        }
    }

    struct Match: Sendable { let fuzzy: ProjectFiles.FuzzyPath?, title: String, command: Bool }
    /// The 200 best matches for `q`, as indices into `items`, best first. Files: fuzzy paths. Everything else: the words of
    /// its title, so "them" finds Color Theme, not random letters.
    nonisolated static func best(_ items: [Match], _ q: String) -> [Int] {
        let fq = ProjectFiles.fuzzyQuery(q)
        return items.indices.compactMap { i -> (Int, Int)? in
            if let f = items[i].fuzzy { return ProjectFiles.fuzzyScore(f, fq).map { (i, $0) } }
            return wordScore(items[i].title, q).map { (i, $0 + (items[i].command ? 2 : 0)) }
        }.sorted { $0.1 > $1.1 }.prefix(200).map(\.0)
    }

    /// Searching, the results come in groups under a heading, the group with the best match first.
    private func setRows(_ items: [Item], grouped: Bool, heading: String? = nil) {
        if grouped {
            var order: [String] = [], byGroup: [String: [Item]] = [:]
            for it in items {
                let g = Self.group(it)
                if byGroup[g] == nil { order.append(g) }
                byGroup[g, default: []].append(it)
            }
            rows = order.flatMap { g in [Row.heading(g)] + (byGroup[g] ?? []).map(Row.item) }
        } else {
            rows = (heading.map { [Row.heading($0)] } ?? []) + items.map(Row.item)
        }
        table.reloadData()
        if let first = rows.firstIndex(where: { if case .item = $0 { true } else { false } }) {
            // A setting's choices open on the one in effect.
            let ticked = field.stringValue.isEmpty ? rows.firstIndex { if case .item(let it) = $0 { it.checked } else { false } } : nil
            table.selectRowIndexes([ticked ?? first], byExtendingSelection: false); table.scrollRowToVisible(ticked ?? 0)
        }
        tryOn()   // the same row index can hold another choice now, so no selection-change call comes
    }
    package func tableViewSelectionDidChange(_ n: Notification) { tryOn() }

    private static func group(_ it: Item) -> String {
        if it.recent { return "Recently Used" }
        return ["File": "Files", "Agent": "Agents", "Terminal": "Terminals", "Command": "Commands", "Setting": "Settings", "Workspace": "Workspaces",
                "Tab": "Tabs"][it.kind]
            ?? it.kind
    }

    /// The commands and settings run from the palette last, newest first; kept per Mac, five of them.
    static let usedKey = "quickOpen.recentCommands"
    private static func usedID(_ it: Item) -> String { [it.kind, it.detail, it.title].joined(separator: " › ") }
    /// Of `pool`, the ones run lately that the menus still offer, in the order they were run.
    static func recentlyUsed(_ pool: [Item]) -> [Item] {
        (UserDefaults.standard.stringArray(forKey: usedKey) ?? []).compactMap { id in
            guard var it = pool.first(where: { usedID($0) == id }) else { return nil }
            it.recent = true
            return it
        }
    }
    static func remember(_ it: Item) {
        guard it.kind == "Command" || it.kind == "Setting" else { return }
        let d = UserDefaults.standard, id = usedID(it)
        d.set(Array(([id] + (d.stringArray(forKey: usedKey) ?? []).filter { $0 != id }).prefix(5)), forKey: usedKey)
    }

    package func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            let split = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            // ↩ right after typing picks from what was typed, once it's scored.
            if let s = scoring { Task { await s.value; choose(split: split) } } else { choose(split: split) }
            return true
        case #selector(NSResponder.deleteBackward(_:)) where commandsOnly && choosing == nil && field.stringValue.isEmpty:
            commandsOnly = false   // ⌫ past the start: back to everything, as deleting VS Code's ">"
            list(query: "")
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if let c = choosing { list(query: c.query); return true }   // a setting's choices: back to the list, the old value back
            panel.orderOut(nil)
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
            return true   // back to the terminal
        default: return false
        }
    }
    /// Up and down skip the groups' headings.
    private func move(_ d: Int) {
        var r = table.selectedRow + d
        while rows.indices.contains(r), case .heading = rows[r] { r += d }
        guard rows.indices.contains(r) else { return }
        table.selectRowIndexes([r], byExtendingSelection: false); table.scrollRowToVisible(r)
    }
    @objc private func activate() { choose(split: false) }
    private func choose(split: Bool) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(r), case .item(let it) = rows[r] else { return }
        Self.remember(it)
        if it.value != nil { it.action(); return }   // a setting with choices lists them; the palette stays
        choosing = nil   // the choice is kept: closing mustn't put the old value back
        panel.orderOut(nil)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        if split, let s = it.split { s() } else { it.action() }
    }
    package func windowDidResignKey(_ n: Notification) { stopChoosing(); panel.orderOut(nil) }

    package func numberOfRows(in t: NSTableView) -> Int { rows.count }
    package func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { if case .item = rows[row] { true } else { false } }
    package func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat { TextSize.of(rows[row].isItem ? Metrics.rowMenu : Metrics.row) }
    package func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        guard case .item(let it) = rows[row] else {
            guard case .heading(let g) = rows[row] else { return nil }
            let h = NSTextField(labelWithString: loc(g))
            h.font = .ui(11, weight: .semibold)
            h.textColor = .secondaryLabelColor
            let v = NSStackView(views: [h]); v.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 0, right: 10)
            return v
        }
        let img = NSImageView(image: it.image ??
            (it.kind == "File" ? app.fileIcons.image(it.title) : NSImage.symbol(it.icon, it.kind)))
        img.contentTintColor = .secondaryLabelColor
        // An agent: its state while there's something to see (as on its tab), else its own icon.
        let lead: NSView
        if let s = it.session, [.working, .waiting, .error].contains(s.status) || (s.status == .done && s.unread) {
            let m = StatusMark(size: 14)
            m.status = s.status
            m.unread = s.unread
            let box = NSView()
            m.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(m)
            NSLayoutConstraint.activate([m.centerXAnchor.constraint(equalTo: box.centerXAnchor), m.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                                         box.heightAnchor.constraint(equalToConstant: 18)])
            lead = box
        } else {
            if let s = it.session, let i = app.catalog.icon(s.agent, size: 18) { img.image = i }
            lead = img
        }
        let t1 = NSTextField(labelWithString: "")
        t1.attributedStringValue = Self.highlighted(it.title, field.stringValue)
        t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: it.detail)
        t2.font = .ui(12)
        t2.textColor = .secondaryLabelColor
        t2.lineBreakMode = it.kind == "Setting" ? .byTruncatingTail : .byTruncatingMiddle   // paths keep both ends, prose its start
        // Empty field: the agents on ⌘1–⌘6 say so (counted past the heading).
        let index = rows[..<row].filter { if case .item = $0 { true } else { false } }.count
        let n = showingRecents && index < 6 && it.kind != "Workspace" ? "⌘\(index + 1)  " : ""
        let kind = NSTextField(labelWithString: n + (showingRecents ? loc(it.kind) : it.value.map { $0 + "  ›" } ?? "")); kind.font = .ui(11)
        kind.textColor = .secondaryLabelColor
        // The choice in effect: a tick at the end, as in a menu.
        let tick = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: String(localized: "Current")) ?? NSImage())
        tick.contentTintColor = .themeAccent; tick.isHidden = !it.checked
        // A command's shortcut: at the end of the title's line, as in a menu.
        let key = NSTextField(labelWithString: it.key)
        key.font = .ui(12)
        key.textColor = .secondaryLabelColor
        key.isHidden = it.key.isEmpty
        key.setContentCompressionResistancePriority(.required, for: .horizontal); key.setContentHuggingPriority(.required, for: .horizontal)
        // One line, as Xcode's Open Quickly: the name, then where it is in grey, which gives way first.
        t1.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        t1.setContentHuggingPriority(.required, for: .horizontal)
        t2.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        t2.setContentHuggingPriority(.init(1), for: .horizontal)   // takes the row's width, so the shortcut sits at its end
        let stack = NSStackView(views: [lead, t1, t2, key, kind, tick])
        stack.spacing = 10
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        lead.widthAnchor.constraint(equalToConstant: 18).isActive = true
        for v in [kind, tick] { v.setContentHuggingPriority(.required, for: .horizontal) }
        let cell = PaletteCell()   // its words turn light on the accent
        cell.pin(stack)
        return cell
    }

}

extension QuickOpen {
    /// The title with what was typed in bold: each word of the query where it first occurs.
    static func highlighted(_ title: String, _ query: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.ui(13)])
        for word in query.split(separator: " ") where !word.isEmpty {
            let r = (title as NSString).range(of: String(word), options: .caseInsensitive)
            if r.location != NSNotFound { s.addAttribute(.font, value: NSFont.ui(13, weight: .bold), range: r) }
        }
        return s
    }
}
