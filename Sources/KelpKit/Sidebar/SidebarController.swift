import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

/// Projects → workspaces → agents in a source-list outline (like Finder and Xcode).
/// Status changes update the visible cells in place; the outline reloads only when the tree's shape changes.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate
{
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    final class Node: NSObject {
        let kind: SidebarItem.Kind
        var children: [Node] = []
        /// A project's own screen, which its row stands for (SidebarItem.workspace).
        var workspace: String?
        init(_ kind: SidebarItem.Kind) { self.kind = kind }
        var key: String {
            switch kind {
            case .project(let id): "p:" + id
            case .workspace(let id): "w:" + id
            case .agent(let id): "a:" + id
            case .host(let host): "h:" + host
            case .parked: "parked"
            }
        }
        /// What a dragged row reorders: a project's or a workspace's id.
        var id: String? {
            switch kind {
            case .project(let id), .workspace(let id): id
            default: nil
            }
        }
    }

    let outline = SidebarOutline()
    private let scroll = SidebarScrollView()
    private var addTrailing = NSLayoutConstraint(), sectionsTrailing = NSLayoutConstraint()
    /// Where the built-ins' blocks go (`Contributions.sidebarSections`).
    weak var sections: NSStackView?
    /// Room at the right that is the sidebar's own: the floater's margin inside its border (8 pt); docked, 0 (the gap
    /// before the editor card is past the column's edge). The cards, Add Project and the limits stop short of it; the
    /// scroller's knob runs in it, off the cards.
    var gutter: CGFloat = 0 {
        didSet {
            guard gutter != oldValue else { return }
            scroll.contentInsets.right = gutter
            scroll.scrollerInsets.right = -gutter
            addTrailing.constant = -6 - gutter
            sectionsTrailing.constant = -gutter
        }
    }
    /// Rows on their way to folded (SidebarFolding): the rows under them have no height and the card ends at them, while
    /// the outline still shows them. The number tells this fold from a later one of the same row.
    var folding: [String: Int] = [:]
    var folds = 0
    /// Rows that just came, at no height until they open out (`settle`).
    var arriving: Set<String> = []
    /// Each project's card, under its rows (`placeCards`).
    var cards: [String: ProjectCard] = [:]
    /// The project whose group the pointer is over (`glow`).
    var glowing: String? {
        didSet {
            if glowing != oldValue {
                glow(oldValue, false)
                glow(glowing, true)
            }
        }
    }
    var roots: [Node] = []
    var shape: [String] = []
    /// Project id → the host it's on: a host's header and projects share one hatched card (`placeCards`).
    var projectHosts: [String: String] = [:]
    /// Room between one server's card and what's over it.
    static let serverGap: CGFloat = 8
    var collapsed: Set<String> {
        get { Set(app.uiState.strings("sidebar.collapsed")) }
        set { app.uiState["sidebar.collapsed"] = try? .from(newValue.sorted()) }
    }
    var syncing = false
    /// The workspace whose project syncSelection last opened (or found open).
    var revealed: String?
    /// The workspace or project (`project`) whose name is being edited in its row.
    var renaming: (id: String, project: Bool)?
    lazy var card = HoverCard(app: app)
    var rowHeights: [CGFloat] = []

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.selectionHighlightStyle = .none   // SidebarRowView draws the selection as a pill
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.pads = { [weak self] row in
            (self?.outline.item(atRow: row) as? Node).flatMap { self?.pads($0) } ?? (0, 0)
        }
        outline.allowsMultipleSelection = true   // ⌘/⇧-click: the menu then acts on all of them
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL, Self.rowType])   // a folder from Finder becomes a project; rows move
        outline.addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false   // it starts under the line over the projects, not under the title bar
        // When the list gets shorter (the limits below load), the selected workspace stays in view.
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOpenInView() }   // queue: .main
        }

        // The built-ins' own blocks (Machines, the plan limits at the foot), under the projects; made again when one is
        // turned on or off.
        let machines = NSStackView()
        machines.orientation = .vertical
        machines.spacing = 0
        sections = machines
        track(owner: self) { [app] in
            app.extensions.all.sidebarSections.map(\.id)
        } changed: { [weak self] _ in
            self?.makeSections()
        }
        // Servers' headers and cards come and go with the built-in that makes them.
        track(owner: self, now: false) { [app] in
            app.extensions.all.servers != nil
        } changed: { [weak self] _ in
            self?.refresh()
        }
        let root = NSView()
        // Over the projects it adds to, where people look for it.
        let add = NSButton.titlebar(
            "folder.badge.plus", String(localized: "Add Project"),
            tip: String(localized: "Add a project: a folder, a clone or one over SSH"))
        add.target = self
        add.action = #selector(addMenu(_:))
        for part in [add, scroll, machines] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(part)
        }
        addTrailing = add.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6)
        let addY = add.centerYAnchor.constraint(equalTo: root.topAnchor)
        track(owner: self) { [app] in TabStrip.height(app.settings) } changed: { band in
            addY.constant = WindowBar.height + band / 2
        }
        sectionsTrailing = machines.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        NSLayoutConstraint.activate([
            // Under the traffic lights, in the window's second row: level with the tab strips and the inspector's panel icons.
            addY,
            addTrailing,
            // In line with the projects' cards (SidebarRowView.band): 8 pt to the window's edge and to the editor area.
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: machines.topAnchor),
            machines.leadingAnchor.constraint(equalTo: root.leadingAnchor), sectionsTrailing,
            machines.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        placeSummary(over: scroll, beside: add)
        followModel()
    }

    /// What the rows follow: the model's projects, sessions and settings, and the clock that moves their times on.
    private func followModel() {
        track(owner: self) { [app] in
            app.repos
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self) { [app] in
            app.worktrees
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self, now: false) { [app] in
            app.missingFolders
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self) { [app] in
            app.workbench.shownSessions
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self) { [app] in
            app.arrangement.order
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self) { [app] in
            app.arrangement.parked
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self) { [app] in
            app.arrangement.parkedBack
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] _ in
            self?.syncSelection()
            self?.updateCard()
        }
        track(owner: self) { [app] in
            app.workbench.page
        } changed: { [weak self] _ in
            self?.syncSelection()
        }
        track(owner: self) { [app] in
            app.workbench.focusedTab
        } changed: { [weak self] _ in
            self?.syncSelection()
        }
        track(owner: self) { [app] in
            app.rowBadges.stats
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
        track(owner: self) { [app] in
            app.extensions.all.ci.map { ci in app.gitFolders.sorted().map { ci.pr($0)?.tip } } ?? []
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
        // Who runs in which machine: their CPU and memory (new every 5 s while one runs) aren't on the rows.
        // The marks built-ins put on agents' rows (a machine one runs in), as they change.
        track(owner: self) { [app] in
            app.sessions.map { s in app.extensions.all.sessionMarks.compactMap { $0(s) } }
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
        track(owner: self) { [app] in
            app.extensions.all.ci?.rows() ?? [:]
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
        followRowLooks()
        track(owner: self) { [app] in
            app.themes.chromeText
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self) { [app] in
            [SettingKeys.rowHeight, SettingKeys.agentDetail, SettingKeys.agentIcons].map { app.settings[$0] }
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
        track(owner: self) { [app] in
            app.settings[SettingKeys.gitBadges]
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
        track(owner: self) { [app] in
            app.settings[SettingKeys.sidebarOrder]
        } changed: { [weak self] _ in
            self?.refresh()
        }
        track(owner: self) { [app] in
            ServerLook.of(app)
        } changed: { [weak self] _ in
            self?.placeCards()
            self?.updateHeaders()
        }
        // "now" becomes "1m": the times on the right move on their own (a clock: nothing is asked of the daemon).
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in   // main run loop
            MainActor.assumeIsolated {
                if self?.view.window?.occlusionState.contains(.visible) == true { self?.updateVisibleCells() }
            }
        }
    }

    func updateVisibleCells() {
        updateCard()
        for row in 0..<outline.numberOfRows {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update()
        }
        updateHeaders()
    }

    // MARK: hover cards

    override func mouseMoved(with event: NSEvent) {
        let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        glowing = row >= 0 && renaming == nil ? project(atRow: row) : nil
        let cell = row >= 0 ? outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell : nil
        guard row >= 0, renaming == nil, let node = outline.item(atRow: row) as? Node,
            cell?.overAction(event.locationInWindow) != true
        else {
            card.hover(nil, rect: .zero, in: outline)
            return
        }
        card.hover(node.workspace.map { "w:" + $0 } ?? node.key, rect: outline.rect(ofRow: row), in: outline)
    }
    override func mouseExited(with event: NSEvent) {
        card.hover(nil, rect: .zero, in: outline)
        glowing = nil
    }
    /// A row's card, now: a click asked for it.
    func openCard(_ node: Node) {
        let row = outline.row(forItem: node)
        if row >= 0 {
            card.open(node.workspace.map { "w:" + $0 } ?? node.key, rect: outline.rect(ofRow: row), in: outline)
        }
    }

}
