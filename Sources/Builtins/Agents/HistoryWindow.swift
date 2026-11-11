import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Every past Claude / Codex conversation on this Mac: search, resume in place, or copy the resume command. The search
/// and the buttons sit in the window's toolbar, as in Xcode's Organizer; the list shows a spinner while it's read and
/// says so in its middle when there's nothing.
@MainActor
final class HistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
    NSToolbarDelegate
{
    private var window: NSWindow?
    private let table = NSTableView()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .init("search"))
    private var search: NSSearchField { searchItem.searchField }
    private let fullText = NSButton(
        checkboxWithTitle: String(localized: "Search inside conversations"), target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let resumeB = NSButton(), copyB = NSButton()
    private let empty = EmptyStateView(), loading = LoadingView()
    private var rows: [AgentSessionInfo] = []
    /// The app whose conversations it lists and resumes.
    private let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init()
    }
    /// Session History (one window per app).
    static func of(_ app: AppModel) -> HistoryWindow { app.part { HistoryWindow(app: app) } }
    private let pending = Debounce()

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        load()
    }

    private func build() {
        for (id, title, width) in [
            ("agent", String(localized: "Agent"), 100.0), ("title", String(localized: "Conversation"), 380),
            ("cwd", String(localized: "Folder"), 260), ("updated", String(localized: "Last active"), 130)
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = TextSize.of(Metrics.row)
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(resume)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        search.placeholderString = String(localized: "Search titles and folders")
        search.delegate = self
        searchItem.preferredWidthForSearchField = 280
        fullText.target = self
        fullText.action = #selector(searchChanged)
        resumeB.title = String(localized: "Resume")
        resumeB.target = self
        resumeB.action = #selector(resume)
        resumeB.bezelStyle = .push
        resumeB.keyEquivalent = "\r"
        copyB.title = String(localized: "Copy Resume Command")
        copyB.target = self
        copyB.action = #selector(copyCommand)
        copyB.bezelStyle = .push
        selectionChanged()
        status.textColor = .secondaryLabelColor
        status.font = .uiDigits(TextSize.caption)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Session History")
        window.animationBehavior = .documentWindow   // the system's own open and close
        let toolbar = NSToolbar(identifier: "history")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden   // the search needs the room; the title stays in the Window menu
        let content = stacked(sv)
        window.contentView = content
        empty.place(in: content)
        loading.place(in: content)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("history")
        window.center()
        self.window = window
    }

    // MARK: toolbar: the search and its option on the left, the count and the buttons on the right

    private static let items: [NSToolbarItem.Identifier] = [
        .init("search"), .init("fullText"), .flexibleSpace,
        .init("status"), .init("copy"), .init("resume")
    ]
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool)
        -> NSToolbarItem?
    {
        if id == searchItem.itemIdentifier { return searchItem }
        let views: [String: NSView] = ["fullText": fullText, "status": status, "copy": copyB, "resume": resumeB]
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = view
        return item
    }

    private lazy var showAll = ClosureButton(title: String(localized: "Show All")) { [weak self] in
        self?.search.stringValue = ""
        self?.load()
    }

    func controlTextDidChange(_ obj: Notification) { searchChanged() }
    @objc private func searchChanged() {
        pending.after(0.25) { [weak self] in self?.load() }
    }

    private func load() {
        let slow = whileSlow { [weak self] in
            self?.empty.show(nil)
            self?.loading.show(String(localized: "Loading…"))
        }
        Task {
            defer {
                slow.cancel()
                loading.show(nil)
            }
            rows =
                await app.call(HistoryList(query: search.stringValue, fullText: fullText.state == .on ? true : nil))
                ?? []
            let query = search.stringValue.trimmingCharacters(in: .whitespaces)
            showCount()
            if !rows.isEmpty {
                empty.show(nil)
            } else if query.isEmpty {
                empty.show(
                    String(localized: "No Conversations Yet"), symbol: "clock.arrow.circlepath",
                    text: String(localized: "Claude Code and Codex conversations on this Mac show here."))
            } else {
                empty.show(
                    String(localized: "No Conversations Match “\(query)”"), symbol: "magnifyingglass",
                    buttons: [showAll])
            }
            table.usesAlternatingRowBackgroundColors = !rows.isEmpty   // stripes with nothing on them read as a list still to come
            table.reloadData()
            selectionChanged()
        }
    }

    /// The count, or nothing: an empty list says so in its middle.
    private func showCount() {
        status.stringValue = rows.isEmpty ? "" : String(localized: "\(rows.count) conversations")
    }

    private func selectionChanged() { for b in [resumeB, copyB] { b.isEnabled = table.selectedRow >= 0 } }
    func tableViewSelectionDidChange(_ n: Notification) { selectionChanged() }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let conversation = rows[row], id = c?.identifier.rawValue
        let text: String
        switch id {
        case "agent": return agentCell(conversation.agent.rawValue)
        case "title": text = conversation.title.isEmpty ? String(localized: "Untitled") : conversation.title
        case "cwd": text = conversation.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        default: text = shortAgo(conversation.updated)   // "4m", "2h", "3d", as everywhere else in Kelp
        }
        let field = NSTextField.label(
            text, font: .ui(TextSize.body), color: id == "updated" ? .secondaryLabelColor : .labelColor,
            truncation: id == "cwd" ? .byTruncatingHead : .byTruncatingTail)
        return NSStackView(views: [field])   // in the row's middle, on the agent's line
    }
    /// The agent as the sidebar shows it: its icon and its name from the catalog.
    private func agentCell(_ agent: String) -> NSView {
        let name = NSTextField.label(app.catalog.name(agent), font: .ui(TextSize.body), color: .secondaryLabelColor)
        let cell = NSStackView(views: [NSImageView(image: app.catalog.icon(agent) ?? NSImage()), name])
        cell.spacing = Metrics.gap
        return cell
    }
    /// Drag a conversation onto a terminal pane: drops its resume command there.
    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        command(rows[row]) as NSString
    }

    private func command(_ conversation: AgentSessionInfo) -> String {
        let cwd = ShellQuote.word(conversation.cwd)
        return conversation.agent == .codex
            ? "cd \(cwd) && codex resume \(conversation.id)" : "cd \(cwd) && claude --resume \(conversation.id)"
    }
    @objc private func copyCommand() {
        guard table.selectedRow >= 0 else { return }
        copyText(command(rows[table.selectedRow]))
        status.stringValue = String(localized: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.linger) { [weak self] in self?.showCount() }
    }
    @objc private func resume() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return }
        Task {
            guard let session = await app.call(HistoryResume(session: rows[row])) else { return }
            app.upsert(session)
            // A conversation from a folder that isn't a project opens in the workspace on screen (it keeps its own folder).
            if let worktreeId = session.worktreeId { app.workbench.show(workspace: worktreeId) }
            app.workbench.open(TabURI.session(session.id))
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
