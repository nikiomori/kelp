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
    answered: Int? = nil, check: Int = 0, asked: Int? = nil
) -> OverviewPage {
    var item = ArtifactItem(
        slug: title, type: type, title: title, created: now.timeIntervalSince1970 - hoursAgo * 3600,
        target: "/\(repo)/\(title)", points: points, answered: answered)
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

/// Each source lists its pages newest first; an archived page shows only under Archive, and the filter finds by words.
@Test func overviewSourcesFilterPages() {
    let pages = [
        page("Sidebar", hoursAgo: 3), page("Review", type: "review", hoursAgo: 1, points: 3, answered: 0),
        page("Calculator", repo: "kuarka", hoursAgo: 2), page("Old", hoursAgo: 90)
    ]
    let pinned: Set = ["/kelp/Sidebar"], archived: Set = ["/kelp/Old"]
    func titles(_ source: OverviewSource, find: String = "") -> [String] {
        OverviewPages.shown(pages, in: source, pinned: pinned, archived: archived, find: find).map(\.item.title)
    }
    #expect(titles(.all) == ["Review", "Calculator", "Sidebar"])
    #expect(titles(.waiting) == ["Review"])
    #expect(titles(.pinned) == ["Sidebar"])
    #expect(titles(.archive) == ["Old"])
    #expect(titles(.project("kelp")) == ["Review", "Sidebar"])
    #expect(titles(.kind("review")) == ["Review"])
    #expect(titles(.all, find: "calc") == ["Calculator"])

    let counts = OverviewPages.counts(pages, [.all, .waiting, .archive], pinned: pinned, archived: archived)
    #expect(counts == [.all: 3, .waiting: 1, .archive: 1])
    #expect(OverviewPages.projects(pages) == ["kelp", "kuarka"])
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
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled], backing: .buffered,
        defer: true)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = controller.view
    controller.viewDidAppear()
    #expect(controller.model.source == .project(rig.project.id))
    #expect(try await waitFor(10) { controller.grid.sections.flatMap(\.pages).count == 4 })
    #expect(OverviewPages.shown(controller.model.pages, in: .waiting, pinned: [], archived: []).count == 1)

    controller.model.source = .all
    let sidebar = try #require(controller.model.pages.first { $0.item.title.hasPrefix("Sidebar") })
    controller.model.togglePin([sidebar.id])
    #expect(try await waitFor(10) { controller.grid.sections.first?.title == "Pinned" })
    #expect(
        controller.grid.sections.flatMap(\.pages).count == 5,
        "\(controller.grid.sections.map { ($0.title, $0.pages.map { "\($0.item.title)@\($0.worktree)" }) })")
    #expect(controller.list.pages.map(\.id).sorted() == controller.grid.sections.flatMap(\.pages).map(\.id).sorted())
    #expect(try await waitFor(30) { controller.model.pictures.images.count == 5 })

    guard let dir = ProcessInfo.processInfo.environment["KELP_SHOT"] else { return }
    for (name, list) in [("artifacts-grid", false), ("artifacts-list", true)] {
        controller.grid.scroll.isHidden = list
        controller.list.scroll.isHidden = !list
        let view = controller.view
        for _ in 0..<3 {   // the grid lays out at its width a turn after it shows
            view.layoutSubtreeIfNeeded()
            await mainActorTurns()
        }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        withExtendedLifetime(window) {}
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
