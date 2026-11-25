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
/// one project's, one kind's, one tag's, or the pages an agent's last change touched (the bar's Show).
enum OverviewSource: Hashable, Sendable {
    case all, waiting, pinned, archive
    case project(String)
    case kind(String)
    case tag(String)
    case changed(by: String)
}

/// An agent's change still to undo: which chat, when its last step was, and how many pages it archived and tagged.
struct OverviewAgentChange: Equatable {
    var session: String, at: Double, archived: Int, tagged: Int
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

    /// Whether `page` belongs to `source`. Archived pages belong only to Archive, and to the change that archived them.
    static func belongs(_ page: OverviewPage, to source: OverviewSource, pinned: Set<String>) -> Bool {
        let away = page.item.archived == true
        switch source {
        case .changed(let session): return page.item.agentChange?.session == session
        case .archive: return away
        case _ where away: return false
        case .all: return true
        case .waiting: return waits(page.item)
        case .pinned: return pinned.contains(page.id)
        case .project(let repo): return page.repo == repo
        case .kind(let kind): return page.item.type == kind
        case .tag(let tag): return page.item.tags?.contains(tag) == true
        }
    }

    /// The pages of `source` whose words hold `find`, newest first. A `#word` in `find` asks for that tag.
    static func shown(
        _ pages: [OverviewPage], in source: OverviewSource, pinned: Set<String>, find: String = "",
        words: (OverviewPage) -> String = { $0.item.title }
    ) -> [OverviewPage] {
        let parts = find.split(separator: " ")
        let tags = parts.filter { $0.hasPrefix("#") }.compactMap { Artifacts.tag(String($0)) }
        let text = parts.filter { !$0.hasPrefix("#") }.joined(separator: " ")
        return pages.filter { page in
            belongs(page, to: source, pinned: pinned)
                && tags.allSatisfy { page.item.tags?.contains($0) == true }
                && (text.isEmpty || words(page).localizedCaseInsensitiveContains(text))
        }
        .sorted { $0.time > $1.time }
    }

    /// How many pages each of `sources` holds.
    static func counts(_ pages: [OverviewPage], _ sources: [OverviewSource], pinned: Set<String>)
        -> [OverviewSource: Int]
    {
        var counts: [OverviewSource: Int] = [:]
        for source in sources { counts[source] = pages.count(where: { belongs($0, to: source, pinned: pinned) }) }
        return counts
    }

    /// The last agent's change still to undo, newer than `seen` (when the user closed the bar): what the latest chat
    /// to change pages did, counted over every page it changed.
    static func agentChange(_ pages: [OverviewPage], seen: Double) -> OverviewAgentChange? {
        let changed = pages.compactMap { page in page.item.agentChange.map { (page.item, $0) } }
        guard let last = changed.max(by: { $0.1.at < $1.1.at })?.1, last.at > seen else { return nil }
        let mine = changed.filter { $0.1.session == last.session }
        let archived = mine.count(where: { $0.0.archived == true && $0.1.archived != true })
        return OverviewAgentChange(
            session: last.session, at: last.at, archived: archived, tagged: mine.count - archived)
    }

    /// The projects and kinds that have pages, most pages first, so the column lists only sources with something in
    /// them.
    static func projects(_ pages: [OverviewPage]) -> [String] { byCount(pages.map(\.repo)) }
    static func kinds(_ pages: [OverviewPage]) -> [String] { byCount(pages.map(\.item.type)) }
    static func tags(_ pages: [OverviewPage]) -> [String] {
        byCount(pages.filter { $0.item.archived != true }.flatMap { $0.item.tags ?? [] })
    }

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
