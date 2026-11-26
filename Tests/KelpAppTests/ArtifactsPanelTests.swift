import AppKit
import Core
import DesignKit
import Foundation
import TestSupport
import Testing

@testable import BuiltinFiles
@testable import KelpKit

/// The project's name in front of a title goes (the panel shows one project); a name that only starts the same stays.
@Test func artifactTitlesLoseTheProjectsName() {
    #expect(ArtifactsPanel.shortTitle("Kelp — ревью 232f2997", project: "Kelp") == "Ревью 232f2997")
    #expect(ArtifactsPanel.shortTitle("Kelp: базы данных для агентов", project: "Kelp") == "Базы данных для агентов")
    #expect(ArtifactsPanel.shortTitle("kelp - plan", project: "Kelp") == "Plan")
    #expect(ArtifactsPanel.shortTitle("Kelp и конкуренты", project: "Kelp") == "Kelp и конкуренты")
    #expect(ArtifactsPanel.shortTitle("Kelpie: notes", project: "Kelp") == "Kelpie: notes")
    #expect(ArtifactsPanel.shortTitle("Kelp —", project: "Kelp") == "Kelp —")
    #expect(ArtifactsPanel.shortTitle("Kelp — plan", project: nil) == "Kelp — plan")
}

/// Pages fall under Today / Yesterday / Previous 7 Days / Earlier by their last change, after the pages agents work on
/// now; one title is one row, the latest, with the earlier ones under it.
@Test func artifactRowsAreDaysAndFoldedTitles() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 11, minute: 40)) ?? Date()
    func at(_ hoursAgo: Double) -> Double { now.timeIntervalSince1970 - hoursAgo * 3600 }
    #expect(ArtifactsPanel.section(at(1), now: now, calendar: calendar) == "Today")
    #expect(ArtifactsPanel.section(at(14), now: now, calendar: calendar) == "Yesterday")
    #expect(ArtifactsPanel.section(at(72), now: now, calendar: calendar) == "Previous 7 Days")
    #expect(ArtifactsPanel.section(at(24 * 9), now: now, calendar: calendar) == "Earlier")

    func page(_ title: String, _ hoursAgo: Double) -> ArtifactItem {
        ArtifactItem(slug: title + "\(hoursAgo)", type: "page", title: title, created: at(hoursAgo), target: title)
    }
    let items = [page("Review", 1), page("Sidebar", 2), page("Sidebar", 50), page("Plan", 51)]
    func shape(busy: Set<String> = []) -> [String] {
        ArtifactsPanel.rows(items, title: \.title, now: now, busy: busy).map { row -> String in
            switch row {
            case .heading(let text): "# \(text)"
            case .item(let item, let earlier): "\(item.title) \(earlier.count)"
            }
        }
    }
    #expect(shape() == ["# Today", "Review 0", "Sidebar 1", "# Previous 7 Days", "Plan 0"])
    // A page an agent works on now leads, under Now.
    #expect(shape(busy: ["Plan"]) == ["# Now", "Plan 0", "# Today", "Review 0", "Sidebar 1"])
}

/// The filter sits over the list it filters, where every panel's filter is, not at the panel's foot.
@MainActor @Test func artifactsFilterSitsOverItsList() throws {
    func fields(_ view: NSView) -> [NSSearchField] {
        ((view as? NSSearchField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
    }
    let panel = ArtifactsPanel(app: AppModel(builtins: []))
    let filter = try #require(fields(panel.view).first)
    let list = try #require(panel.table.enclosingScrollView)
    let parts = try #require(list.superview as? NSStackView).arrangedSubviews
    let filterAt = try #require(parts.firstIndex { filter.isDescendant(of: $0) })
    let listAt = try #require(parts.firstIndex(of: list))
    #expect(filterAt < listAt)
}

extension OneAtATime {
    /// A panel whose first answer is slow says it is reading, so its empty list isn't taken for nothing there. The answer
    /// takes the wait away once the wait has had its moment, and the rows show.
    @Test func aPanelWaitingForItsFirstAnswerSaysSo() async throws {
        let app = AppModel(builtins: []), folder = tmp().path
        app.repos = [Repo(id: "r", name: "Atlas", path: folder)]
        app.worktrees = [Worktree(id: "own", repoId: "r", branch: "main", path: folder, createdAt: .distantPast)]
        app.workbench.show(workspace: "own")
        let panel = ArtifactsPanel(app: app)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView?.addSubview(panel.view)
        LoadingView.patience = 0.05
        defer { LoadingView.patience = 1 }
        panel.viewDidAppear()
        #expect(!panel.loading.showing)
        #expect(try await waitFor(10) { panel.loading.showing })
        let page = ArtifactItem(
            slug: "p", type: "page", title: "Plan", created: Date().timeIntervalSince1970, target: "/tmp/p.html")
        app.land(ArtifactsEvent(worktree: "own", items: [page]))
        #expect(try await waitFor(10) { !panel.loading.showing && panel.rows.count == 2 })
    }
}

/// A read of the pages that fails keeps the pages read before, under a line that says why. With none read before, the
/// reason takes the list's place, and the next read that works shows its pages.
@MainActor @Test func aFailedReadOfThePagesIsSaidInThePanel() async throws {
    func texts(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.filter { !$0.isHidden }.flatMap(texts)
    }
    let app = AppModel(builtins: []), folder = tmp().path
    app.repos = [Repo(id: "r", name: "Atlas", path: folder)]
    app.worktrees = [Worktree(id: "own", repoId: "r", branch: "main", path: folder, createdAt: .distantPast)]
    app.workbench.show(workspace: "own")
    let panel = ArtifactsPanel(app: app)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView?.addSubview(panel.view)
    panel.viewDidAppear()
    app.land(ArtifactsEvent(worktree: "own", items: [], error: "disk I/O error"))
    #expect(try await waitFor(10) { texts(panel.view).contains("disk I/O error") })
    #expect(panel.rows.isEmpty && panel.failureBar.shown == nil)
    let page = ArtifactItem(
        slug: "p", type: "page", title: "Plan", created: Date().timeIntervalSince1970, target: "/tmp/p.html")
    app.land(ArtifactsEvent(worktree: "own", items: [page]))
    #expect(try await waitFor(10) { panel.rows.count == 2 })
    app.land(ArtifactsEvent(worktree: "own", items: [], error: "disk I/O error"))
    #expect(try await waitFor(10) { panel.failureBar.shown == "disk I/O error" })
    #expect(panel.rows.count == 2)
}

/// The filter finds a page by its kind too, in either language's word for it, not only by its title.
@MainActor @Test func theFilterFindsAPageByItsKind() {
    let panel = ArtifactsPanel(app: AppModel(builtins: []))
    let deck = ArtifactItem(
        slug: "q3", type: "slides", title: "Q3 review", created: 0, target: "/p/.kelp/artifacts/q3/slides.md")
    let words = panel.words(deck, nil)
    #expect(words.contains("Q3 review") && words.contains("slides") && words.contains(ArtifactStart.title(.slides)))
}
