// The pages that agents drive with `kelp browser`, and how they show outside the page's own tab.
import AppKit
import Core
import DesignKit
import KelpKit

/// Tracks what each page driven by an agent (or one of its subagents) is doing. It feeds the browser mark on the
/// agent's row, the glow on the page's tab, and the page in the agent's card. The mark is lit in the agent's colour for
/// `litFor` seconds after each action, and grey while the page is only open. The pages report here through `drives`,
/// `acted`, `change` and `closed`. The marks the shell shows (`BrowserMarks`) observe this model, and through it ask a
/// page for its picture or to come forward. The app has one.
@MainActor
@Observable
final class AgentPages {
    static func of(_ app: AppModel) -> AgentPages { app.part { AgentPages(app: app) } }

    /// How long a page stays lit after an action.
    static let litFor: TimeInterval = 10
    /// How many steps a page keeps for the card.
    static let keptSteps = 3

    struct Step: Equatable, Sendable {
        let text: String, at: Date
    }
    /// Who has the page: the agent, the user (they took it), or the user because the agent asked (`kelp browser ask`).
    enum Holder: Equatable, Sendable {
        case agent, user
        case asked(String)
    }
    struct Page: Equatable {
        var session: String, subagent: String?
        /// The workspace and the tab that hold the page.
        var workspace: String, tab: String
        var title = "", url = ""
        /// The colour of the agent's pointer on the page. It is the agent's colour, made to stand out on a page.
        var color: NSColor = .systemPurple
        /// The last few things the agent did on the page, oldest first.
        var steps: [Step] = []
        /// How many errors the page has reported since it was opened, and the last one.
        var errors = 0
        var lastError: String?
        var holder: Holder = .agent
    }

    /// The pages by id. There is one id for each web view an agent drives.
    private(set) var pages: [String: Page] = [:]
    /// The pages that acted in the last `litFor` seconds.
    private(set) var lit: Set<String> = []
    static let remotePrefix = "remote:"

    struct Scope: Hashable {
        let workspace: String, owner: String, subagent: String?
    }
    struct Visit {
        let tab: String, sharedSite: String?
    }
    /// The last tab for each caller. A shared grant names both the tab and the site and lasts only in this app.
    @ObservationIgnored var browsed: [Scope: Visit] = [:]
    @ObservationIgnored private var handles: [String: WeakPage] = [:]
    @ObservationIgnored private var dimming: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    // MARK: told by the browser

    /// Records that page `id` is now driven, as `page` describes. `handle` is the tab that takes the page's picture and
    /// acts on the user's buttons.
    func drives(_ id: String, _ page: Page, handle: BrowserTab) {
        handles[id] = WeakPage(page: handle)
        if pages[id] != page { pages[id] = page }
    }

    func change(_ id: String, _ edit: (inout Page) -> Void) {
        guard var page = pages[id] else { return }
        edit(&page)
        if pages[id] != page { pages[id] = page }
    }

    /// Records an action on page `id`. The action becomes the page's last step, and the page stays lit for `litFor`.
    func acted(_ id: String, _ step: String) {
        change(id) { page in
            page.steps.append(Step(text: step, at: Date()))
            if page.steps.count > Self.keptSteps { page.steps.removeFirst(page.steps.count - Self.keptSteps) }
        }
        lit.insert(id)
        dimming[id]?.cancel()
        dimming[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.litFor)) } catch { return }   // cancelled by a newer action
            self?.lit.remove(id)
        }
    }

    func closed(_ id: String) {
        pages[id] = nil
        lit.remove(id)
        handles[id] = nil
        dimming.removeValue(forKey: id)?.cancel()
    }

    // MARK: read by the marks

    /// Returns the pages of a session: the session's own pages first, then those of its subagents. Within each group
    /// the page that acted most recently comes first.
    func of(session: String) -> [(id: String, page: Page)] {
        pages.filter { $0.value.session == session }.map { (id: $0.key, page: $0.value) }.sorted {
            ($0.page.subagent == nil ? 0 : 1, -($0.page.steps.last?.at.timeIntervalSince1970 ?? 0), $0.id)
                < ($1.page.subagent == nil ? 0 : 1, -($1.page.steps.last?.at.timeIntervalSince1970 ?? 0), $1.id)
        }
    }

    /// The pages in tab `tab`.
    func of(tab: String) -> [(id: String, page: Page)] {
        pages.filter { $0.value.tab == tab }.map { (id: $0.key, page: $0.value) }
    }

    /// What the browser mark on a session's row shows. `mark(for:)` returns nil when the session has no page. `color`
    /// is set while one of the session's pages acted lately, and `holder` says who has the page when that is the user.
    struct Mark: Equatable {
        let color: NSColor?, holder: Holder
    }
    func mark(for session: String) -> Mark? {
        let own = of(session: session)
        guard !own.isEmpty else { return nil }
        let held = own.lazy.map(\.page.holder).first { $0 != .agent } ?? .agent
        return Mark(color: own.first { lit.contains($0.id) }?.page.color, holder: held)
    }

    /// The subagents of `session` that acted on a page lately.
    func litSubagents(of session: String) -> Set<String> {
        Set(of(session: session).filter { lit.contains($0.id) }.compactMap(\.page.subagent))
    }

    /// Returns the colour of the glow on a tab. It is the agent's colour while a page in the tab acted lately.
    func glow(tab: String) -> NSColor? {
        of(tab: tab).first { lit.contains($0.id) }?.page.color
    }

    func handle(_ id: String) -> BrowserTab? { handles[id]?.page }

    /// Brings up the workspace that holds the page, with the page in front.
    func show(_ id: String) {
        guard let page = pages[id] else { return }
        app.workbench.show(workspace: page.workspace)
        app.workbench.selectTab(page.tab, in: page.workspace)
        handle(id)?.bringForward()
    }
}

private struct WeakPage {
    weak var page: BrowserTab?
}
