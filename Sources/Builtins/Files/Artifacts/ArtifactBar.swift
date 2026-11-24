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
    /// The agents' working ring while its agent writes the page (still under Reduce Motion).
    private let ring = StatusMark(size: 12)
    lazy var back = IconButton(.symbol("chevron.left"), tip: String(localized: "Older Version")) {
        [weak self] in self?.step(-1)
    }
    lazy var forward = IconButton(.symbol("chevron.right"), tip: String(localized: "Newer Version")) {
        [weak self] in self?.step(1)
    }
    let count = TextButton("")   // "2 of 5", a button on the bar's plate as its neighbours
    let latest = TextButton(String(localized: "Show Latest"))
    let restore = TextButton(String(localized: "Restore"))
    private let author = TextButton("")
    /// On a canvas, the result of Kelp's check of the drawn boards: what it found wrong (`CanvasScript`).
    private let check = TextButton("")
    /// What the chat that made the page spent on it, in calls and dollars, as quiet text (Claude Code chats only). It
    /// and `fresh` give way in a narrow pane before `status` does, which says what state the page is in.
    private let spent = NSTextField.label("", font: .uiDigits(TextSize.row), color: .secondaryLabelColor)
    private var spentAt: Double?
    /// The View / Mark / Edit control. On a canvas it sets what a click on a board does: nothing, a mark for the agent,
    /// or a change by hand.
    private let modes = CapsuleSegments(
        labels: [String(localized: "View"), String(localized: "Mark"), String(localized: "Edit")],
        name: String(localized: "Mode"))
    /// The Present button. It shows a canvas's boards one at a time, each as large as the pane, like slides in a deck.
    let present = TextButton(String(localized: "Present"))
    /// The button that counts the changes the agent's last turn made to a doc. A click goes to the next change.
    private let changes = TextButton("")
    /// On a dashboard, the time its figures were drawn, and an Update button that asks the agent to run them again.
    private let fresh = NSTextField.label("", font: .uiDigits(TextSize.row), color: .secondaryLabelColor)
    let refresh = TextButton(String(localized: "Update"))
    /// The kept version a doc's changes are counted from.
    var baselineN: Int?
    private var issues: [String] = []
    /// The page's marks with an agent and to check, as the last artifacts list counted them.
    private var marks: ArtifactMarkCounts?
    /// The canvas's modified time from the last artifacts list: the latest change to its boards or its design system.
    private var canvasTime: Double?
    private lazy var more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More Actions")) {
        [weak self] in self?.showMore()
    }
    var item: ArtifactItem?
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
        count.font = .uiDigits(TextSize.row)
        count.onClick = { [weak self] in self?.showVersions() }
        latest.onClick = { [weak self] in self?.show(nil) }
        restore.onClick = { [weak self] in self?.restoreShown() }
        author.imagePosition = .imageLeading
        author.onClick = { [weak self] in self?.goToChat() }
        check.isHidden = true
        check.onClick = { [weak self] in self?.showCheck() }
        for quiet in [spent, fresh] { quiet.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal) }
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
        modes.isHidden = ![.canvas, .motion, .markdown, .slides].contains(markdown.page)
        if markdown.page == .motion {
            modes.setToolTip(String(localized: "Play it"), forSegment: 0)
        } else if markdown.page != .canvas {
            modes.setToolTip(String(localized: "Read the page"), forSegment: 0)
            modes.setToolTip(
                String(localized: "Select text to mark it, then send your notes to the agent"), forSegment: 1)
            modes.setToolTip(String(localized: "Its Markdown beside the page"), forSegment: 2)
        }
        markdown.onPageMode = { [weak self] in self?.modes.selectedSegment = $0.rawValue }
        present.toolTip = String(localized: "One at a time, as large as the pane: ← → step, esc ends")
        present.isHidden = markdown.page != .canvas && markdown.page != .slides
        changes.isHidden = true
        changes.toolTip = String(
            localized: "What its agent’s last turn changed, marked beside the text: click for the next")
        changes.onClick = { [weak self] in self?.markdown.runJS("kelpChange(1)") }
        markdown.onChanges = { [weak self] count in
            self?.changes.isHidden = count == 0
            self?.changes.title = String(localized: "\(count) Changes")
        }
        fresh.isHidden = true
        refresh.isHidden = true
        refresh.toolTip = String(localized: "Run its sources again, or ask its agent to")
        refresh.onClick = { [weak self] in self?.markdown.askUpdate() }
        present.onClick = { [weak self] in self?.togglePresenting() }
        markdown.onPresentEnded = { [weak self] in self?.present.title = String(localized: "Present") }
        let bar = Bar.content(
            [kind, ring, status],
            [
                spent, latest, restore, fresh, refresh, changes, devices(), modes, present, check, back, count, forward,
                author, more
            ],
            stretching: status
        )
        // In a narrow pane Present goes into ⋯ first, then the check's result, as Xcode's narrow bars do. The words
        // are cut before either goes; `showMore` lists what is out. A stack detaches only when its clipping resistance
        // is below its views' (required, by default, squeezes them instead); the words' 250 stays under it.
        bar.stack.setClippingResistancePriority(.defaultHigh - 1, for: .horizontal)
        bar.stack.setVisibilityPriority(.init(rawValue: 300), for: present)
        bar.stack.setVisibilityPriority(.init(rawValue: 400), for: check)
        return bar
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
        if item?.marks != marks {
            // Marks handed back (or answered) by an agent: a canvas draws again for Before, a doc takes them in place.
            if marks != nil || item?.marks != nil {
                markdown.marksChanged(redraw: (item?.marks?.check ?? 0) > (marks?.check ?? 0))
            }
            marks = item?.marks
            modes.setCount(marks.flatMap { $0.check > 0 ? $0.check : nil }, forSegment: 1)
        }
        if let title = item?.title ?? recorded?.title, !title.isEmpty { markdown.onPageTitle?(title, pageKind) }
        // The current file goes last. When it hasn't changed since the last kept version, the two are the same page,
        // so that version is dropped and the current file takes its turn's label.
        let versions = item?.versions ?? []
        let live = item?.changed != false || versions.isEmpty
        entries =
            versions.dropLast(live ? 0 : 1).map {
                Entry(
                    version: $0, label: $0.byUser == true ? String(localized: "By hand: \($0.label)") : $0.label,
                    at: $0.at)
            }
            + [
                Entry(
                    version: nil, label: live ? String(localized: "As it is now") : versions.last?.label ?? "",
                    at: item?.modified)
            ]
        versionsPanel?.reload()
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
        ring.status = writing && shown == nil ? .working : nil   // hides itself without one
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
        check.isHidden = found.isEmpty   // nothing to fix: nothing to show
        check.title = String(localized: "\(found.count) to Fix")
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

    /// The check's findings with their fixes: the column's Check tab, in Mark.
    private func showCheck() {
        markdown.setCanvasMode(.mark)
        modes.selectedSegment = MarkdownTab.CanvasMode.mark.rawValue
        markdown.runJS("window.kelpMarks?.openTab?.('check')")
    }

    /// Present and the check's result, while a narrow pane keeps them out of the bar.
    private func addCrowdedOut(to menu: NSMenu) {
        let out = (view as? Bar)?.stack.detachedViews.filter { !$0.isHidden && ($0 == present || $0 == check) } ?? []
        if out.contains(present) { menu.add(present.title) { [weak self] in self?.togglePresenting() } }
        if out.contains(check) { menu.add(check.title) { [weak self] in self?.showCheck() }.toolTip = check.toolTip }
        if !out.isEmpty { menu.addItem(.separator()) }
    }

    private func showMore() {
        let menu = NSMenu(), app = self.app, path = self.path, md = markdown
        addCrowdedOut(to: menu)
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
        if md.page == .canvas, !md.isDashboard {
            menu.add(String(localized: "View"), submenu: md.viewMenu())
            menu.addItem(.separator())
        }
        if md.page == .slides { md.presentItems(menu) }
        if md.page == .motion {   // the agent makes the video again in other shapes (MarkdownTab+Adapt)
            menu.add(String(localized: "Also in Other Formats…")) { md.askAdaptations() }
            menu.addItem(.separator())
        }
        // Slides have their own PDF, a page a slide (Export); printing would cut them by the sheet.
        if md.page != .slides { menu.add(String(localized: "Print or Save as PDF…")) { md.printPage() } }
        exportItems(menu)
        menu.addItem(.separator())
        WorkspaceActions.addLocate(
            to: menu, path: path,
            copies: [(String(localized: "Relative Path"), { @MainActor in copyText(Artifacts.projectPath(path)) })])
        // The author's button goes to the chat; here only while the bar has no room for it.
        let authorShown = !author.isHidden && !((view as? Bar)?.stack.detachedViews.contains(author) ?? false)
        if !authorShown, let id = item?.session, app.session(id)?.status != .exited {
            menu.add(String(localized: "Show the Chat That Made It")) { app.workbench.focus(session: id) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    private func goToChat() { if let id = item?.session { app.workbench.focus(session: id) } }
}
