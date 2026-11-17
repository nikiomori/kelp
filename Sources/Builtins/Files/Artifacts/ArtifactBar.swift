import AppKit
import Core
import DesignKit
import KelpKit

/// The bar over a page an agent made (`.kelp/artifacts/<name>/doc.md`). It shows the page's kind, whether the agent
/// is writing it, its versions (one per agent turn, stepped with ‹ › or picked from a list), the chat that made it,
/// and a ⋯ menu. An older version shows in the preview, read-only, until Show Latest. Restore writes it back as the
/// file.
@MainActor
final class ArtifactBar: NSObject {
    /// A version the bar can show: a kept version, or the current file when `version` is nil.
    struct Entry {
        var version: ArtifactVersion?
        var label: String
        var at: Double?
    }

    let app: AppModel, path: String
    unowned let markdown: MarkdownTab   // the tab that holds this bar
    private let watched: Watched
    private let workspace: String?
    /// `path` without symlinks, as the daemon lists it.
    private let real: String
    /// The page's kind: not a path, so it isn't quiet like one. It truncates before the buttons do.
    private let kind = NSTextField.label("", font: .ui(TextSize.row, weight: .medium))
    let status = NSTextField.label("", font: .ui(TextSize.row), color: .secondaryLabelColor)
    private let ring = NSProgressIndicator()
    private lazy var back = IconButton(.symbol("chevron.left"), tip: String(localized: "Older Version")) {
        [weak self] in self?.step(-1)
    }
    private lazy var forward = IconButton(.symbol("chevron.right"), tip: String(localized: "Newer Version")) {
        [weak self] in self?.step(1)
    }
    let count = PointerButton()
    private let latest = TextButton(String(localized: "Show Latest"))
    private let restore = TextButton(String(localized: "Restore"))
    private let author = TextButton("")
    /// On a canvas, the result of Kelp's check of the drawn boards: what it found wrong (`CanvasScript`).
    private let check = TextButton("")
    /// What the chat that made the page spent on it, in calls and dollars, as quiet text (Claude Code chats only).
    private let spent = NSTextField(labelWithString: "")
    private var spentAt: Double?
    /// The View / Mark / Edit control. On a canvas it sets what a click on a board does: nothing, a mark for the agent,
    /// or a change by hand.
    private let modes = NSSegmentedControl(
        labels: [String(localized: "View"), String(localized: "Mark"), String(localized: "Edit")],
        trackingMode: .selectOne, target: nil, action: nil)
    /// The Present button. It shows a canvas's boards one at a time, each as large as the pane, like slides in a deck.
    private let present = TextButton(String(localized: "Present"))
    /// The button that counts the changes the agent's last turn made to a doc. A click goes to the next change.
    private let changes = TextButton("")
    /// On a dashboard, the time its figures were drawn, and an Update button that asks the agent to run them again.
    private let fresh = NSTextField(labelWithString: "")
    private let refresh = TextButton(String(localized: "Update"))
    /// The kept version a doc's changes are counted from.
    var baselineN: Int?
    private var issues: [String] = []
    /// The canvas's modified time from the last artifacts list: the latest change to its boards or its design system.
    private var canvasTime: Double?
    private lazy var more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More")) { [weak self] in
        self?.showMore()
    }
    private var item: ArtifactItem?
    /// The page's own record, read from artifact.json when the artifacts list doesn't have the page. `pageKind` comes
    /// from the list's item or from this record.
    private var recorded: ArtifactRecord?
    private(set) var pageKind: Artifacts.Kind?
    var entries: [Entry] = []
    /// The number of the version on screen, or nil for the current file. A number, unlike an index, stays the same when
    /// versions are added or dropped.
    var shownN: Int?
    /// The index of the shown version in `entries` now.
    var shown: Int? { shownN.flatMap { number in entries.firstIndex { $0.version?.n == number } } }

    private(set) lazy var view: NSView = {
        ring.style = .spinning
        ring.controlSize = .small
        count.font = .uiDigits(TextSize.row)
        count.padding = Metrics.gap
        count.onClick = { [weak self] in self?.showVersions() }
        latest.onClick = { [weak self] in self?.show(nil) }
        restore.onClick = { [weak self] in self?.restoreShown() }
        author.imagePosition = .imageLeading
        author.onClick = { [weak self] in self?.goToChat() }
        check.isHidden = true
        check.onClick = { [weak self] in self?.showCheck() }
        spent.font = .uiDigits(TextSize.row)
        spent.textColor = .secondaryLabelColor
        spent.isHidden = true
        modes.controlSize = .small
        modes.font = .ui(TextSize.row)
        modes.selectedSegment = markdown.canvasMode.rawValue
        modes.setToolTip(String(localized: "Look at the boards"), forSegment: 0)
        modes.setToolTip(
            String(localized: "Click elements to mark them, then send your notes to the agent"), forSegment: 1)
        modes.setToolTip(
            String(localized: "Click an element to change its style, double-click a text to retype it"), forSegment: 2)
        modes.target = self
        modes.action = #selector(modeChosen)
        modes.isHidden = ![.canvas, .markdown, .slides].contains(markdown.page)
        if markdown.page != .canvas {
            modes.setToolTip(String(localized: "Read the page"), forSegment: 0)
            modes.setToolTip(
                String(localized: "Select text to mark it, then send your notes to the agent"), forSegment: 1)
            modes.setToolTip(String(localized: "Its Markdown beside the page"), forSegment: 2)
        }
        markdown.onPageMode = { [weak self] in self?.modes.selectedSegment = $0.rawValue }
        present.toolTip = String(localized: "One at a time, as large as the pane: ← → step, Esc ends")
        present.isHidden = markdown.page != .canvas && markdown.page != .slides
        changes.isHidden = true
        changes.toolTip = String(
            localized: "What its agent's last turn changed, marked beside the text: click for the next")
        changes.onClick = { [weak self] in self?.markdown.runJS("kelpChange(1)") }
        markdown.onChanges = { [weak self] count in
            self?.changes.isHidden = count == 0
            self?.changes.title = String(localized: "\(count) Changes")
        }
        fresh.font = .uiDigits(TextSize.row)
        fresh.textColor = .secondaryLabelColor
        fresh.isHidden = true
        refresh.isHidden = true
        refresh.toolTip = String(localized: "Ask its agent to run the numbers again")
        refresh.onClick = { [weak self] in self?.markdown.askUpdate() }
        present.onClick = { [weak self] in self?.togglePresenting() }
        markdown.onPresentEnded = { [weak self] in self?.present.title = String(localized: "Present") }
        return Bar.content(
            [kind, ring, status],
            [
                spent, latest, restore, fresh, refresh, changes, modes, present, check, back, count, forward, author,
                more
            ],
            stretching: status
        )
    }()

    init(app: AppModel, path: String, markdown: MarkdownTab) {
        self.app = app
        self.path = path
        self.markdown = markdown
        watched = Watched(.artifacts, in: app)
        // The workspace whose folder holds the page. When a branch's folder sits inside its project's folder, the
        // innermost workspace wins.
        // Paths are compared with symlinks resolved, because a tab opened as /tmp/… is in the project at
        // /private/tmp/….
        let real = Paths.real(path) ?? path
        self.real = real
        workspace = app.worktree(holding: real)?.id
        super.init()
        markdown.onCheck = { [weak self] in self?.show(check: $0) }
        nameFromRecord()
        watched.key = workspace
        track(owner: self) { [app, workspace] in
            app.latest(ArtifactsEvent.self, workspace ?? "")?.items
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [app] in
            app.sessions.map { "\($0.id)\($0.status)\($0.title)" }
        } changed: { [weak self] _ in
            self?.update()
        }
    }

    /// Returns the page's kind from its file name, for use before its record is read. canvas.json counts as a design
    /// until the record says it's a dashboard.
    static func kind(ofFile path: String) -> Artifacts.Kind? {
        guard isPage(path) else { return nil }
        return Artifacts.Kind.allCases.first { path.hasSuffix("/" + $0.file) }
    }

    /// The tab's icon for a kind of page.
    static func icon(_ kind: Artifacts.Kind) -> NSImage? {
        let (symbol, name) = look(kind)
        return .symbol(symbol, name)
    }

    /// A kind of page's symbol and name, as its tab and its bar show them.
    private static func look(_ kind: Artifacts.Kind) -> (symbol: String, name: String) {
        switch kind {
        case .doc: ("doc.text", String(localized: "Doc"))
        case .review: ("checklist", String(localized: "Review"))
        case .slides: ("play.rectangle", String(localized: "Slides"))
        case .design: ("square.grid.2x2", String(localized: "Design"))
        case .dashboard: ("chart.bar", String(localized: "Dashboard"))
        case .proof: ("checkmark.seal", String(localized: "Proof"))
        }
    }

    /// Returns a page's title and kind from the workspace's artifacts list. A tab that isn't built yet takes its name
    /// from this.
    static func listed(_ path: String, in app: AppModel) -> (title: String, kind: Artifacts.Kind)? {
        guard isPage(path) else { return nil }
        let real = Paths.real(path) ?? path
        guard let workspace = app.worktree(holding: real)?.id,
            let item = app.latest(ArtifactsEvent.self, workspace)?.items.first(where: {
                (Paths.real($0.target) ?? $0.target) == real
            }),
            !item.title.isEmpty, let kind = Artifacts.Kind(rawValue: item.type) ?? kind(ofFile: path)
        else { return nil }
        return (item.title, kind)
    }

    /// Whether `path` is a page Kelp made (`.kelp/artifacts/<name>/<kind>.md`), not one of its kept versions.
    static func isPage(_ path: String) -> Bool {
        guard let range = path.range(of: "/\(Artifacts.folder)/") else { return false }
        let rest = path[range.upperBound...].split(separator: "/")
        return rest.count == 2
            && (Artifacts.Kind.allCases.contains { $0.file == rest[1] }
                || Artifacts.olderFiles.contains(String(rest[1])))
    }

    func update() {
        item = app.latest(ArtifactsEvent.self, workspace ?? "")?.items.first {
            (Paths.real($0.target) ?? $0.target) == real
        }
        let session = item?.session.flatMap(app.session)
        let type = item?.type ?? recorded?.type ?? Self.kind(ofFile: path)?.rawValue ?? ""
        kind.stringValue = Artifacts.Kind(rawValue: type).map { Self.look($0).name } ?? String(localized: "Doc")
        pageKind = Artifacts.Kind(rawValue: type)
        if pageKind == .dashboard { showDashboard() }
        if let time = item?.modified, time != spentAt, item?.url == nil { countSpent(at: time) }
        if markdown.page == .canvas, let time = item?.modified, time != canvasTime {
            if canvasTime != nil { markdown.boardsChanged() }
            canvasTime = time
        }
        if let title = item?.title ?? recorded?.title, !title.isEmpty { markdown.onPageTitle?(title, pageKind) }
        // The current file goes last. When it hasn't changed since the last kept version, the two are the same page,
        // so that version is dropped and the current file takes its turn's label.
        let versions = item?.versions ?? []
        let live = item?.changed != false || versions.isEmpty
        entries =
            versions.dropLast(live ? 0 : 1).map { Entry(version: $0, label: $0.label, at: $0.at) }
            + [
                Entry(
                    version: nil, label: live ? String(localized: "As it is now") : versions.last?.label ?? "",
                    at: item?.modified)
            ]
        if shownN != nil, shown.map({ $0 >= entries.count - 1 }) ?? true {
            shownN = nil
            markdown.showVersion(nil)
        }   // the shown version is gone, or is now the latest
        let writing =
            session?.status == .working && (item?.modified).map { Date().timeIntervalSince1970 - $0 < 120 } == true
        if markdown.page == .canvas { markdown.canvasWriter = writing ? app.catalog.name(session?.agent) : nil }
        if markdown.page == .markdown { followBaseline(versions: versions, live: item?.changed != false) }
        if markdown.page != .canvas { modes.selectedSegment = markdown.canvasMode.rawValue }   // ⇧⌘V may change mode
        if shown != nil {
            status.stringValue = String(localized: "An older version, from \(Self.time(entries[shown ?? 0].at))")
        } else {
            status.stringValue = writing ? String(localized: "\(app.catalog.name(session?.agent)) is writing") : ""
        }
        ring.isHidden = !writing || shown != nil
        if ring.isHidden { ring.stopAnimation(nil) } else { ring.startAnimation(nil) }
        let index = shown ?? entries.count - 1
        count.title = String(localized: "\(index + 1) of \(entries.count)")
        for control in [back, forward, count] as [NSView] { control.isHidden = entries.count < 2 }
        back.isEnabled = index > 0
        forward.isEnabled = index < entries.count - 1
        latest.isHidden = shown == nil
        restore.isHidden = shown == nil
        author.isHidden = session == nil
        if let session {
            // The button names the agent, not the chat's title, because that title reads as the page's own name.
            // The chat's title goes in the tooltip.
            author.title = app.catalog.name(session.agent)   // displayName is the chat's title once it has one
            author.image = session.agent.flatMap { app.catalog.icon($0, size: 14) }
            let tip =
                session.status == .exited
                ? String(localized: "The chat that made it has ended") : String(localized: "Show the Chat That Made It")
            author.toolTip = session.title.isEmpty ? tip : "\(tip): \(session.title)"
            author.isEnabled = session.status != .exited
        }
    }

    /// Sets the bar up for a dashboard: View and Mark only (there is nothing to change by hand), no Present, and the
    /// time its figures were drawn.
    private func showDashboard() {
        _ = view   // builds the view, so its controls are set up before this changes them
        markdown.isDashboard = true
        if modes.segmentCount == 3 { modes.segmentCount = 2 }
        present.isHidden = true
        refresh.isHidden = false
        if let time = item?.modified {
            fresh.isHidden = false
            fresh.stringValue = String(localized: "Data from \(Self.time(time))")
        }
    }

    private func show(check found: [String]) {
        issues = found
        _ = view
        check.isHidden = false
        check.title = found.isEmpty ? String(localized: "No Issues") : String(localized: "\(found.count) to Fix")
        check.toolTip = String(localized: "What Kelp found where it drew the boards: cut-off text, contrast, sizes")
    }

    /// Shows what the chat has spent on the page so far. It runs when the page's file changes, at most every 10 s
    /// while the page is being written.
    private func countSpent(at time: Double) {
        guard spentAt.map({ time - $0 >= 10 }) ?? true else { return }
        spentAt = time
        Task {
            guard let cost = await app.quiet(ArtifactCost(path: path)), let cost else { return }
            _ = view
            spent.isHidden = false
            spent.stringValue = String(localized: "\(cost.calls) steps · \(cost.cost, format: .currency(code: "USD"))")
            spent.toolTip = String(
                localized:
                    "What its chat spent on it: \(cost.output) tokens written, \(cost.read) read, priced as the API would"
            )
        }
    }

    private func togglePresenting() {
        markdown.togglePresenting()
        present.title = markdown.presentingBoards ? String(localized: "Stop Presenting") : String(localized: "Present")
    }

    @objc private func modeChosen() {
        markdown.setCanvasMode(MarkdownTab.CanvasMode(rawValue: modes.selectedSegment) ?? .view)
    }

    /// Names a page that isn't in the workspace's list (one opened from elsewhere) from its own artifact.json, the way
    /// a listed page is named.
    private func nameFromRecord() {
        let record = (path as NSString).deletingLastPathComponent + "/artifact.json"
        Task {
            guard item == nil, let file = await app.quiet(FilesRead(path: record)) else { return }
            do {
                recorded = try Artifacts.decoder.decode(ArtifactRecord.self, from: Data(file.text.utf8))
            } catch { return }
            update()
        }
    }

    private func showCheck() {
        let menu = NSMenu(), md = markdown
        for issue in issues.prefix(20) {
            menu.addItem(
                withTitle: issue.count > 90 ? String(issue.prefix(89)) + "…" : issue, action: nil, keyEquivalent: ""
            )
            .isEnabled = false
        }
        if !issues.isEmpty { menu.addItem(.separator()) }
        if !issues.isEmpty {
            let who = md.pageAuthor.map { app.catalog.name($0.agent) } ?? String(localized: "the Agent")
            menu.add(String(localized: "Ask \(who) to Fix")) { md.sendCheck() }
        }
        menu.add(String(localized: "Check Again")) { md.rerender() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: check.bounds.height + 4), in: check)
    }

    private func showMore() {
        let menu = NSMenu(), app = self.app, path = self.path, md = markdown
        if modes.isHidden {   // a review: these show its Markdown beside or instead of the page (others use `modes`)
            for (mode, title) in [String(localized: "Edit"), String(localized: "Split"), String(localized: "Preview")]
                .enumerated()
            {
                let item = menu.add(title) { md.modeSegment = mode }
                item.state = md.modeSegment == mode ? .on : .off
                item.isEnabled = md.shownVersion == nil   // an older version is read-only
            }
            menu.addItem(.separator())
        }
        menu.add(String(localized: "Print or Save as PDF…")) { md.printPage() }
        menu.addItem(.separator())
        menu.add(String(localized: "Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        menu.add(String(localized: "Copy Path")) {
            copyText(Artifacts.projectPath(path))
        }
        if let id = item?.session, app.session(id)?.status != .exited {
            menu.add(String(localized: "Show the Chat That Made It")) { app.workbench.focus(session: id) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    private func goToChat() { if let id = item?.session { app.workbench.focus(session: id) } }
}
