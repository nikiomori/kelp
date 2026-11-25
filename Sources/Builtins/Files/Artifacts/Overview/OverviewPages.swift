import Core
import Foundation

/// A page as Artifacts Overview lists it: the panel's item, and the workspace and project it is in.
struct OverviewPage: Equatable, Sendable {
    var item: ArtifactItem
    var worktree: String, repo: String
    var id: String { item.target }
    var time: Double { item.modified ?? item.created }
}

/// What the overview's column of sources picks: every page, those waiting for the user, the pinned or archived ones,
/// one project's, or one kind's.
enum OverviewSource: Hashable, Sendable {
    case all, waiting, pinned, archive
    case project(String)
    case kind(String)
}

/// The overview's lists, worked out from the pages and what the user pinned or archived. Archived pages show only under
/// Archive; pinned ones lead the list, in their own section.
enum OverviewPages {
    /// Whether a page waits for the user: a review not answered in full, marks to check, or the agent's question.
    static func waits(_ item: ArtifactItem) -> Bool {
        if let points = item.points, points > 0, (item.answered ?? 0) < points { return true }
        guard let marks = item.marks else { return false }
        return marks.check > 0 || (marks.asked ?? 0) > 0
    }

    /// Whether `page` belongs to `source`.
    static func belongs(_ page: OverviewPage, to source: OverviewSource, pinned: Set<String>, archived: Set<String>)
        -> Bool
    {
        let away = archived.contains(page.id)
        switch source {
        case .archive: return away
        case _ where away: return false
        case .all: return true
        case .waiting: return waits(page.item)
        case .pinned: return pinned.contains(page.id)
        case .project(let repo): return page.repo == repo
        case .kind(let kind): return page.item.type == kind
        }
    }

    /// The pages of `source` whose words hold `find`, newest first.
    static func shown(
        _ pages: [OverviewPage], in source: OverviewSource, pinned: Set<String>, archived: Set<String>,
        find: String = "", words: (OverviewPage) -> String = { $0.item.title }
    ) -> [OverviewPage] {
        let find = find.trimmingCharacters(in: .whitespaces)
        return pages.filter {
            belongs($0, to: source, pinned: pinned, archived: archived)
                && (find.isEmpty || words($0).localizedCaseInsensitiveContains(find))
        }
        .sorted { $0.time > $1.time }
    }

    /// How many pages each of `sources` holds.
    static func counts(
        _ pages: [OverviewPage], _ sources: [OverviewSource], pinned: Set<String>, archived: Set<String>
    ) -> [OverviewSource: Int] {
        var counts: [OverviewSource: Int] = [:]
        for source in sources {
            counts[source] = pages.count(where: { belongs($0, to: source, pinned: pinned, archived: archived) })
        }
        return counts
    }

    /// The projects and kinds that have pages, most pages first, so the column lists only sources with something in
    /// them.
    static func projects(_ pages: [OverviewPage]) -> [String] { byCount(pages.map(\.repo)) }
    static func kinds(_ pages: [OverviewPage]) -> [String] { byCount(pages.map(\.item.type)) }

    private static func byCount(_ keys: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// The pages in sections: the pinned first (unless the list is the pinned ones), then by day as the panel groups
    /// them (Today, Yesterday, Previous 7 Days, Earlier). `shown` comes newest first.
    static func sections(
        _ shown: [OverviewPage], pinned: Set<String>, source: OverviewSource, now: Date, calendar: Calendar = .current
    ) -> [(title: String, pages: [OverviewPage])] {
        let lead = source == .pinned || source == .archive ? [] : shown.filter { pinned.contains($0.id) }
        var sections: [(title: String, pages: [OverviewPage])] = []
        if !lead.isEmpty { sections.append((String(localized: "Pinned"), lead)) }
        for page in shown where !lead.contains(page) {
            let title = ArtifactsPanel.section(page.time, now: now, calendar: calendar)
            if sections.last?.title == title {
                sections[sections.count - 1].pages.append(page)
            } else {
                sections.append((title, [page]))
            }
        }
        return sections
    }
}
