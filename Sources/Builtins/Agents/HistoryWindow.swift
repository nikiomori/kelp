import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Every past Claude / Codex conversation on this Mac, to search, resume in place, or copy the resume command for. The
/// search and the buttons sit in the window's toolbar, as in Xcode's Organizer. The list shows a spinner while it is
/// read, and says so in its middle when there is nothing.
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
    private let empty = EmptyStateView(), loading = LoadingView(rows: true, rowHeight: Metrics.row)
    private var rows: [AgentSessionInfo] = []
    /// The app whose conversations it lists and resumes.
    private let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init()
    }
    /// Returns the Session History window, one per app.
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
        // A failed read over rows already listed keeps them, with a line over them saying so.
        let content = NSStackView(views: [failure, sv])
        content.orientation = .vertical
        content.distribution = .fill
        content.spacing = 0
        failure.setHuggingPriority(.defaultHigh, for: .vertical)
        for view in [failure, sv] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
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
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool
    )
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

    private lazy var failure = FailureBar { [weak self] in self?.load() }
    private lazy var tryAgain = ClosureButton(title: String(localized: "Try Again")) { [weak self] in self?.load() }

    private func load() {
        // Only an empty list waits in view; rows already listed stay while the next read runs.
        let slow = whileSlow { [weak self] in
            guard let self, self.rows.isEmpty else { return }
            self.empty.show(nil)
            self.loading.show(String(localized: "Reading the history…"))
        }
        Task {
            defer {
                slow.cancel()
                loading.show(nil)
            }
            let (read, error) = await app.tryCall(
                HistoryList(query: search.stringValue, fullText: fullText.state == .on ? true : nil))
            if let error, read == nil { return failed(error) }
            failure.show(nil)
            rows = read ?? []
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

    /// A read that failed: over rows already listed, a line saying so; with none, the error in the list's place.
    private func failed(_ error: String) {
        guard rows.isEmpty else { return failure.show(error) }
        empty.showError(String(localized: "Couldn’t Read the History"), text: error, buttons: [tryAgain])
    }

    /// Shows the count in the toolbar, or nothing when the list is empty, because an empty list says so in its middle.
    private func showCount() {
        status.stringValue = rows.isEmpty ? "" : String(localized: "\(rows.count) conversations")
    }

    private func selectionChanged() { for b in [resumeB, copyB] { b.isEnabled = table.selectedRow >= 0 } }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }

    func numberOfRows(in table: NSTableView) -> Int { rows.count }
    func tableView(_ table: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let conversation = rows[row], id = tableColumn?.identifier.rawValue
        let text: String
        switch id {
        case "agent": return agentCell(conversation.agent.rawValue)
        case "title": text = conversation.title.isEmpty ? String(localized: "Untitled") : conversation.title
        case "cwd": text = (conversation.cwd as NSString).abbreviatingWithTildeInPath
        default: text = shortAgo(conversation.updated)   // "4m", "2h", "3d", as everywhere else in Kelp
        }
        let field = NSTextField.label(
            text, font: .ui(TextSize.body), color: id == "updated" ? .secondaryLabelColor : .labelColor,
            truncation: id == "cwd" ? .byTruncatingHead : .byTruncatingTail)
        return NSStackView(views: [field])   // the stack centres the text in the row, level with the agent cell
    }
    /// The agent as the sidebar shows it: its icon and its name from the catalog.
    private func agentCell(_ agent: String) -> NSView {
        let name = NSTextField.label(app.catalog.name(agent), font: .ui(TextSize.body), color: .secondaryLabelColor)
        let cell = NSStackView(views: [NSImageView(image: app.catalog.icon(agent) ?? NSImage()), name])
        cell.spacing = Metrics.gap
        return cell
    }
    /// Dragging a conversation onto a terminal pane drops its resume command there.
    func tableView(_ table: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
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
        status.crossfade()   // the same way the commit card shows "Copied"
        status.stringValue = String(localized: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.linger) { [weak self] in
            self?.status.crossfade()
            self?.showCount()
        }
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
