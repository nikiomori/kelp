import AppKit
import Core
import Foundation
import TestSupport
import Testing

@testable import BuiltinFiles
@testable import KelpKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func page(
    _ title: String, repo: String = "kelp", type: String = "page", hoursAgo: Double = 1, points: Int? = nil,
    answered: Int? = nil, check: Int = 0, asked: Int? = nil, tags: [String]? = nil, archived: Bool? = nil,
    changedBy: String? = nil, before: Bool? = nil
) -> OverviewPage {
    var item = ArtifactItem(
        slug: title, type: type, title: title, created: now.timeIntervalSince1970 - hoursAgo * 3600,
        target: "/\(repo)/\(title)", points: points, answered: answered)
    item.tags = tags
    item.archived = archived
    item.agentChange = changedBy.map {
        ArtifactAgentChange(session: $0, at: now.timeIntervalSince1970 - hoursAgo * 3600, tags: nil, archived: before)
    }
    if check > 0 || asked != nil {
        var marks = ArtifactMarkCounts(sent: 0, check: check)
        marks.asked = asked
        item.marks = marks
    }
    return OverviewPage(item: item, worktree: repo + "-w", repo: repo)
}

/// What waits for the user: a review not answered in full, marks to check, or the agent's question. A review answered
/// in full, a page with marks still with the agent, and a plain page don't.
@Test(arguments: [
    (page("r", points: 9, answered: 1), true),
    (page("r", points: 9, answered: 9), false),
    (page("m", check: 2), true),
    (page("q", asked: 1), true),
    (page("p"), false)
])
func overviewWaitingIsWhatAsksTheUser(page: OverviewPage, waits: Bool) {
    #expect(OverviewPages.waits(page.item) == waits)
}

/// Each source lists its pages newest first; an archived page shows only under Archive (and the change that archived
/// it), and the filter finds by words, with `#tag` for a tag.
@Test func overviewSourcesFilterPages() {
    let pages = [
        page("Sidebar", hoursAgo: 3, tags: ["design"]),
        page("Review", type: "review", hoursAgo: 1, points: 3, answered: 0, tags: ["design", "review"]),
        page("Calculator", repo: "kuarka", hoursAgo: 2), page("Old", hoursAgo: 90, archived: true, changedBy: "s")
    ]
    let pinned: Set = ["/kelp/Sidebar"]
    func titles(_ source: OverviewSource, find: String = "") -> [String] {
        OverviewPages.shown(pages, in: source, pinned: pinned, find: find).map(\.item.title)
    }
    #expect(titles(.all) == ["Review", "Calculator", "Sidebar"])
    #expect(titles(.waiting) == ["Review"])
    #expect(titles(.pinned) == ["Sidebar"])
    #expect(titles(.archive) == ["Old"])
    #expect(titles(.project("kelp")) == ["Review", "Sidebar"])
    #expect(titles(.kind("review")) == ["Review"])
    #expect(titles(.tag("design")) == ["Review", "Sidebar"])
    #expect(titles(.changed(by: "s")) == ["Old"])
    #expect(
        OverviewPages.shown(pages, in: .now, pinned: pinned, busy: ["/kuarka/Calculator"]).map(\.item.title) == [
            "Calculator"
        ])
    #expect(titles(.all, find: "calc") == ["Calculator"])
    #expect(titles(.all, find: "#Review") == ["Review"])
    #expect(titles(.all, find: "#design side") == ["Sidebar"])

    let counts = OverviewPages.counts(pages, [.all, .waiting, .archive], pinned: pinned)
    #expect(counts == [.all: 3, .waiting: 1, .archive: 1])
    #expect(OverviewPages.projects(pages) == ["kelp", "kuarka"])
    #expect(OverviewPages.tags(pages) == ["design", "review"])
}

/// The bar offers the latest agent's change, counting what it archived and what it only tagged, until the user closes
/// it; an older chat's change isn't counted in.
@Test func overviewOffersTheLastAgentsChange() {
    let pages = [
        page("A", hoursAgo: 1, archived: true, changedBy: "s2"), page("B", hoursAgo: 2, tags: ["x"], changedBy: "s2"),
        page("C", hoursAgo: 3, archived: true, changedBy: "s2", before: true), page("D", hoursAgo: 5, changedBy: "s1")
    ]
    let change = OverviewPages.agentChange(pages, seen: 0)
    #expect(change.map { [$0.session, "\($0.archived)", "\($0.tagged)"] } == ["s2", "1", "2"])
    #expect(OverviewPages.agentChange(pages, seen: change?.at ?? 0) == nil)
}

/// The pinned pages lead in their own section; the rest fall under the panel's days. Under Pinned itself there is no
/// second Pinned section.
@Test func overviewSectionsPutThePinnedFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let shown = [page("A", hoursAgo: 1), page("B", hoursAgo: 2), page("C", hoursAgo: 60)]
    let pinned: Set = ["/kelp/B"]
    func shape(_ source: OverviewSource) -> [String] {
        OverviewPages.sections(shown, pinned: pinned, source: source, now: now, calendar: calendar)
            .map { "\($0.title): " + $0.pages.map(\.item.title).joined(separator: " ") }
    }
    #expect(shape(.all) == ["Pinned: B", "Today: A", "Previous 7 Days: C"])
    #expect(shape(.pinned) == ["Today: A B", "Previous 7 Days: C"])
}

/// The tab opens on the project on screen and lists every project's pages under All, as the daemon reads them from
/// their folders; a page pinned leads its list, and the list view shows the same pages as the grid. Each card gets its
/// page's picture. With KELP_SHOT set it writes pictures of the grid and the list.
@MainActor @Test func theOverviewListsEveryProjectsPages() async throws {
    let rig = try await AppRig()
    defer { rig.done() }
    let app = rig.app
    let other = rig.root.appendingPathComponent("kuarka_web").path
    try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
    try Git.run(["init", "-q", "-b", "main"], cwd: other, remotes: .none)
    let second = try await rig.client.call(RepoAdd(path: other))
    let secondSpace = try #require(try await rig.client.call(WorktreeList(repoId: second.id)).first)
    if !app.repos.contains(where: { $0.id == second.id }) { app.repos.append(second) }   // the daemon may have told
    if !app.worktrees.contains(where: { $0.id == secondSpace.id }) { app.worktrees.append(secondSpace) }

    let now = Date()
    func made(_ title: String, _ kind: Artifacts.Kind, hoursAgo: Double, in root: String, text: String) throws {
        let dir = Artifacts.dir(root: root).appendingPathComponent(title.lowercased().filter(\.isLetter))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let when = now.addingTimeInterval(-hoursAgo * 3600)
        let page = dir.appendingPathComponent(kind.file)
        try "# \(title)\n\n\(text)\n".write(to: page, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: page.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ArtifactRecord(type: kind.rawValue, title: title, created: when, file: kind.file))
            .write(to: dir.appendingPathComponent("artifact.json"))
    }
    let words = "The sidebar keeps one row per chat.\n\n- Groups fold\n- Branches show under their chat"
    try made("Final design audit", .doc, hoursAgo: 1, in: rig.repo, text: words)
    try made("Agent dashboard notes", .doc, hoursAgo: 3, in: rig.repo, text: words)
    try made("Sidebar groups and branches", .doc, hoursAgo: 26, in: rig.repo, text: words)
    try made("Design review", .review, hoursAgo: 30, in: rig.repo, text: "## 1. Rows\n- [ ] A. one\n- [ ] B. two")
    try made("Savings calculator", .doc, hoursAgo: 28, in: other, text: words)

    let controller = OverviewController(model: OverviewModel(app: app))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered,
        defer: true)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = controller.view
    controller.viewDidAppear()
    #expect(controller.model.source == .project(rig.project.id))
    #expect(try await waitFor(10) { controller.grid.sections.flatMap(\.pages).count == 4 })
    #expect(OverviewPages.shown(controller.model.pages, in: .waiting, pinned: []).count == 1)

    controller.model.source = .all
    let sidebar = try #require(controller.model.pages.first { $0.item.title.hasPrefix("Sidebar") })
    controller.model.togglePin([sidebar.id])
    #expect(try await waitFor(10) { controller.grid.sections.first?.title == "Pinned" })
    #expect(
        controller.grid.sections.flatMap(\.pages).count == 5,
        "\(controller.grid.sections.map { ($0.title, $0.pages.map { "\($0.item.title)@\($0.worktree)" }) })")
    #expect(controller.list.pages.map(\.id).sorted() == controller.grid.sections.flatMap(\.pages).map(\.id).sorted())
    // A window on screen is laid out every frame; this one, never shown, only when asked.
    #expect(
        try await waitFor(30) {
            controller.view.layoutSubtreeIfNeeded()
            return controller.model.pictures.images.count == 5
        })

    // An agent tags two pages and archives one through the daemon: the tags show, the bar offers its change, and Undo
    // puts the archived page back.
    let model = controller.model
    let calculator = try #require(model.pages.first { $0.item.title.hasPrefix("Savings") })
    let review = try #require(model.pages.first { $0.item.type == "review" })
    model.setStyle(TagStyle(emoji: "🎨", color: .blue), for: "design-system")
    for (page, archive) in [(sidebar, false), (review, false), (calculator, true)] {
        let folder = try #require(model.folder(page))
        _ = await app.call(
            ArtifactChange(
                folder: folder, add: page.item.type == "review" ? ["review", "design-system"] : ["design-system"],
                archived: archive ? true : nil, session: "agent-1"))
    }
    #expect(try await waitFor(10) { model.agentChange?.archived == 1 && model.agentChange?.tagged == 2 })
    #expect(model.tags == ["design-system", "review"])
    #expect(try await waitFor(10) { controller.grid.sections.flatMap(\.pages).count == 4 })

    // A chat edits the review now: its face is on the card and the card says so; the Now source lists it.
    var chat = Session(id: "c1", cwd: rig.repo, command: "claude")
    chat.agent = Session.claudeAgent
    chat.status = .working
    chat.page = SessionPage(target: review.id, doing: .editing, at: Date())
    app.sessions.append(chat)
    #expect(try await waitFor(10) { ArtifactActions.note(review.item, app)?.text.hasSuffix(" is editing") == true })
    #expect(OverviewPages.shown(model.pages, in: .now, pinned: [], busy: model.busy).map(\.id) == [review.id])

    if let dir = ProcessInfo.processInfo.environment["KELP_SHOT"] {
        for _ in 0..<3 { await mainActorTurns() }   // the tab follows the chat a turn later
        try shoot(controller, window, to: dir)
    }
    model.undo(try #require(model.agentChange))
    #expect(try await waitFor(10) { model.pages.allSatisfy { $0.item.archived != true && $0.item.tags == nil } })
    #expect(model.agentChange == nil)
}

/// Writes pictures of the overview's grid and list.
@MainActor private func shoot(_ controller: OverviewController, _ window: NSWindow, to dir: String) throws {
    for (name, list) in [("artifacts-grid", false), ("artifacts-list", true)] {
        controller.grid.scroll.isHidden = list
        controller.list.scroll.isHidden = !list
        let view = controller.view
        for _ in 0..<3 {   // the grid lays out at its width a turn after it shows
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date())
        }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        withExtendedLifetime(window) {}
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}

/// The pages take the width the sources leave, however the tab was first laid out (at no size, as a new tab is).
@MainActor @Test func thePagesTakeTheTabsWidth() async throws {
    let app = AppModel(builtins: [])
    app.repos = [Repo(id: "k", name: "Kelp", path: "/k")]
    app.worktrees = [Worktree(id: "kw", repoId: "k", branch: "main", path: "/k", createdAt: .distantPast)]
    app.workbench.show(workspace: "kw")
    let controller = OverviewController(model: OverviewModel(app: app))
    let view = controller.view
    view.frame = .zero
    view.layoutSubtreeIfNeeded()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 800), styleMask: [.titled, .resizable],
        backing: .buffered, defer: true)
    window.contentView = view
    controller.viewDidAppear()
    app.land(ArtifactsEvent(worktree: "kw", items: (1...6).map { page("P\($0)", hoursAgo: Double($0)).item }))
    #expect(try await waitFor(10) { controller.grid.sections.flatMap(\.pages).count == 6 })
    view.layoutSubtreeIfNeeded()
    for width in [500.0, 1400] {
        window.setContentSize(NSSize(width: width, height: 800))
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            await mainActorTurns()
        }
        #expect(
            controller.grid.scroll.frame.width > width - 300,
            "\(width): \(controller.grid.scroll.frame)")
        let second = controller.grid.collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame
        let first = controller.grid.collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
        if width > 1000 {
            #expect(first?.minY == second?.minY, "side by side at \(width): \(String(describing: first))")
        }
    }
}
