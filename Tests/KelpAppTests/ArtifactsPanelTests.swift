import Core
import Foundation
import Testing

@testable import BuiltinFiles

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

/// Pages fall under Today / Yesterday / Previous 7 Days / Earlier by their last change; one title is one row, the
/// latest, with the earlier ones under it.
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
    let rows = ArtifactsPanel.rows(items, title: \.title, now: now)
    let shape = rows.map { row -> String in
        switch row {
        case .heading(let text): "# \(text)"
        case .item(let item, let earlier): "\(item.title) \(earlier.count)"
        }
    }
    #expect(shape == ["# Today", "Review 0", "Sidebar 1", "# Previous 7 Days", "Plan 0"])
}
