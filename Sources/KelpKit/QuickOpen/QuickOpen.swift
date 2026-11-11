import AppKit
import Core
import DesignKit
import WorkbenchKit

/// ⌘P: files, worktrees, agents, tabs, commands in one fuzzy list; "#123" finds a pull request, ":120" a line, "@" a symbol,
/// "/" a file and nothing else. ⇧⌘P: commands only.
/// Empty, it lists the agents to get back to — those that need you first — on ⌘1–⌘6, in an order that holds still
/// while it's open. ⇧↩ opens the choice in a split. A setting with choices (Color Theme, File Icon Theme, on/off…) lists them
/// right here, the one in effect ticked; for looks, moving through them tries each on, ↩ keeps it, esc goes back.
@MainActor
final class QuickOpen: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init()
    }

    var choosing: Choosing?
    var rows: [Row] = []
    /// The file's symbols while ⌘P is open (`QuickOpenPrefixes`).
    var symbols: (path: String, items: [Item])?
    var symbolLoad: Task<Void, Never>?

    var panel: QuickPanel!
    /// What the empty field shows, made once per opening so rows don't move under the pointer.
    var recents: [Item] = []
    var showingRecents = false
    /// Fading away (`hide`).
    var hiding = false
    var prSearch: Task<Void, Never>?
    var filesLoad: Task<Void, Never>?
    /// The typed query's matches being scored; the next keystroke cancels it.
    var scoring: Task<Void, Never>?
    let field = PaletteField()
    let table = PaletteTable()
    let keys = Keycaps()
    var all: [Item] = []
    var commandsOnly = false
    /// The title bar's Search pill, which the palettes grow out of.
    weak var anchor: NSView?
    /// A list of its own instead of the palette's — tmux sessions (`showTmux`), a built-in's (`showList`): its rows for
    /// what's typed. Nil for the palette.
    var own: (@MainActor (String) async -> [Item])?
    var tmuxLoad: Task<Void, Never>?

    /// `text`: what the field starts with (":" for Go to Line).
    func show(commandsOnly: Bool, text: String = "") {
        if panel == nil { build() }
        self.commandsOnly = commandsOnly
        symbols = nil
        list(query: "")
        if !text.isEmpty {
            field.stringValue = text
            filter()
        }
        present()
    }

    /// Out of the title bar's Search pill (`anchor`), as if the pill widened into the field and the list dropped from it;
    /// without the pill on screen, under the window's top.
    func present() {
        if hiding {
            hiding = false
            NSAnimationContext.runAnimationGroup {
                $0.duration = Motion.fast
                panel.animator().alphaValue = 1
            }   // turned back on its way out
        } else {
            panel.alphaValue = 1
        }
        guard let window = anchor?.window ?? NSApp.mainWindow else { return show() }
        let size = panel.frame.size, windowFrame = window.frame
        guard let pill = anchor, pill.window === window, !pill.isHiddenOrHasHiddenAncestor else {
            panel.setFrameOrigin(NSPoint(x: windowFrame.midX - size.width / 2, y: windowFrame.maxY - size.height - 120))
            return show()
        }
        let pillFrame = window.convertToScreen(pill.convert(pill.bounds, to: nil))
        let left = min(max(pillFrame.midX - size.width / 2, windowFrame.minX + 8), windowFrame.maxX - size.width - 8)
        let end = NSRect(x: left, y: pillFrame.maxY + 6 - size.height, width: size.width, height: size.height)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(end, display: false)
            return show()
        }
        // At its full size from the start, faint and a little up towards the pill, and down into place: growing from
        // the pill's size, it was laid out and its glass resized for every frame.
        panel.setFrame(end.offsetBy(dx: 0, dy: Metrics.gapWide), display: false)
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
    func list(query: String) {
        stopChoosing()
        tmuxLoad?.cancel()
        own = nil
        field.placeholderString =
            commandsOnly
            ? String(localized: "Run a command") : String(localized: "Search chats, tabs, files and commands")
        let label = commandsOnly ? String(localized: "Commands") : String(localized: "Search")
        field.setAccessibilityLabel(label)
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.image = .symbol(
            commandsOnly ? "command" : "magnifyingglass", label)
        // The keys it knows, under the list (they're not written anywhere else).
        keys.stringValue =
            commandsOnly
            ? String(localized: "↑↓ Select    ↩ Run    ⌫ Everything")
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
        choosing = Choosing(
            key: spec.key, saved: store.values[spec.key], tries: section.id == "appearance", query: field.stringValue)
        all = choices(spec).map { v, name in
            let (note, image) = spec.key == SettingKeys.theme.key ? self.themeLook(v.string ?? "") : ("", nil)
            return Item(
                kind: "Choice", icon: v.string == "ghostty" ? "terminal" : "", title: name, detail: note,
                action: { store.set(spec.key, v) },
                choice: v, checked: v == now, image: image)
        }
        field.placeholderString = "\(loc(section.title)) › \(loc(spec.title))"
        keys.stringValue =
            choosing?.tries == true
            ? String(localized: "↑↓ Try On    ↩ Keep    esc Back")
            : String(localized: "↑↓ Select    ↩ Choose    esc Back")
        field.stringValue = ""
        filter()
    }

    /// Leaves a setting's choices with the value it had: what was tried on goes away.
    func stopChoosing() {
        if let setting = choosing { app.settings.preview(setting.key, setting.saved) }
        choosing = nil
    }

    /// The selected choice, on screen while it's selected (looks only).
    private func tryOn() {
        guard let setting = choosing, setting.tries, rows.indices.contains(table.selectedRow),
            case .item(let it) = rows[table.selectedRow]
        else { return }
        app.settings.preview(setting.key, it.choice)
    }

    func build() {
        panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered, defer: false)
        panel.onNumber = { [weak self] n in self?.pickRecent(n) ?? false }
        panel.title = String(localized: "Open Quickly")   // hidden; the Window menu and VoiceOver read it
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.hidesOnDeactivate = true
        // Gone when another window takes the keys; observed rather than delegated, so the shell declares less for built-ins.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey), name: NSWindow.didResignKeyNotification, object: panel)
        panel.isReleasedWhenClosed = false
        // Spotlight's ground: Liquid Glass on macOS 26, the popover material before. Its views go in `effect`.
        let effect = NSView()
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Metrics.radiusXL
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
        field.font = .ui(TextSize.heading)
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(filterAction)
        let col = NSTableColumn(identifier: .init("i"))
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.backgroundColor = .clear
        table.target = self
        table.doubleAction = #selector(activate)
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        let line = NSBox()
        line.boxType = .separator
        let top = NSBox()
        top.boxType = .separator   // under the field, which is the panel's top, not a box of its own
        for v in [field, top, sv, line, keys] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            top.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            sv.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            sv.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            sv.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            sv.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -4),
            line.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -28),
            keys.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            keys.centerYAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14)
        ])
    }

    private func pickRecent(_ n: Int) -> Bool {
        guard showingRecents, recents.indices.contains(n - 1), recents[n - 1].kind != "Group" else { return false }
        hide()
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        recents[n - 1].action()
        return true
    }

    /// An uppercase key equivalent means ⇧ too.
    static func shortcut(_ i: NSMenuItem) -> String {
        var mods = KeySpec.Modifiers(i.keyEquivalentModifierMask)
        if i.keyEquivalent != i.keyEquivalent.lowercased() { mods.insert(.shift) }
        return KeyBindings.display(KeySpec(key: i.keyEquivalent, mods: mods))
    }

    @objc private func filterAction() { filter() }
    func controlTextDidChange(_ obj: Notification) {
        // ">" first, as in VS Code: the commands, with what follows it.
        if !commandsOnly, choosing == nil, own == nil, field.stringValue.hasPrefix(">") {
            commandsOnly = true
            list(query: String(field.stringValue.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }
        filter()
    }

    func filter() {
        scoring?.cancel()
        let typed = field.stringValue
        if let own {
            scoring = Task { [weak self] in
                let items = await own(typed)
                guard let self, !Task.isCancelled else { return }
                setRows(items, grouped: false)
            }
            return
        }
        let prefix = commandsOnly || choosing != nil ? nil : Prefix(typed)
        if let prefix {
            showingRecents = false
            if filterPrefix(prefix) { return }
        }
        var filesOnly: String?
        if case .files(let name)? = prefix { filesOnly = name }
        let query = filesOnly ?? typed
        let pool =
            filesOnly != nil
            ? all.filter { $0.kind == "File" }
            : commandsOnly && choosing == nil ? all.filter { $0.kind == "Command" || $0.kind == "Setting" } : all
        if filesOnly != nil, query.isEmpty {
            setRows(Array(pool.prefix(200)), grouped: false)
            return
        }
        if !commandsOnly, choosing == nil, query.hasPrefix("#") {
            setRows([], grouped: false)
            searchPullRequests(query)
            return
        }
        if query.isEmpty {
            showingRecents = !commandsOnly && choosing == nil && !recents.isEmpty
            let used = commandsOnly && choosing == nil ? Self.recentlyUsed(pool) : []
            let ids = Set(used.map(Self.usedID))
            let rest = (commandsOnly ? pool : pool.filter { $0.kind != "File" }).filter {
                !ids.contains(Self.usedID($0))
            }
            setRows(
                showingRecents ? recents : used + Array(rest.prefix(200)),
                grouped: (!showingRecents && !commandsOnly && choosing == nil) || !used.isEmpty,
                heading: showingRecents ? "Recent" : nil)
        } else {
            showingRecents = false
            // Off the main thread: a big project's files take a while to score on every keystroke.
            let grouped = !commandsOnly && choosing == nil,
                keys = pool.map { Match(fuzzy: $0.fuzzy, title: $0.title, command: $0.kind == "Command") }
            scoring = Task { [weak self] in
                let best = await Task.detached { Self.best(keys, query) }.value
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
            if let fuzzy = items[i].fuzzy { return ProjectFiles.fuzzyScore(fuzzy, fq).map { (i, $0) } }
            return wordScore(items[i].title, q).map { (i, $0 + (items[i].command ? 2 : 0)) }
        }.sorted { $0.1 > $1.1 }.prefix(200).map(\.0)
    }

    /// Searching, the results come in groups under a heading, the group with the best match first.
    func setRows(_ items: [Item], grouped: Bool, heading: String? = nil) {
        if grouped {
            var order: [String] = [], byGroup: [String: [Item]] = [:]
            for it in items {
                let group = Self.group(it)
                if byGroup[group] == nil { order.append(group) }
                byGroup[group, default: []].append(it)
            }
            rows = order.flatMap { g in [Row.heading(g)] + (byGroup[g] ?? []).map(Row.item) }
        } else {
            rows = (heading.map { [Row.heading($0)] } ?? []) + items.map(Row.item)
        }
        table.reloadData()
        if let first = rows.firstIndex(where: { if case .item = $0 { true } else { false } }) {
            // A setting's choices open on the one in effect.
            let ticked =
                field.stringValue.isEmpty
                ? rows.firstIndex { if case .item(let it) = $0 { it.checked } else { false } } : nil
            table.selectRowIndexes([ticked ?? first], byExtendingSelection: false)
            table.scrollRowToVisible(ticked ?? 0)
        }
        tryOn()   // the same row index can hold another choice now, so no selection-change call comes
    }
    func tableViewSelectionDidChange(_ n: Notification) { tryOn() }
}
