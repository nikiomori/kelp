// The pages agents drive (`kelp browser`), as they show outside the page's own tab.
import AppKit
import Core
import DesignKit
import KelpKit

/// What each page an agent (or one of its subagents) drives is doing: the browser mark on the agent's row, lit in the
/// agent's colour for a while after each action (`litFor`) and grey while the page is only open; the glow on the page's
/// tab; the page in the agent's card. The pages tell it (`drives`, `acted`, `change`, `closed`); the marks the shell
/// shows (`BrowserMarks`) read it under observation, and ask a page for its picture or to come forward. The app's one.
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
        init(_ text: String, at: Date = Date()) {
            self.text = text
            self.at = at
        }
    }
    /// Who has the page: the agent, the user (they took it), or the user because the agent asked (`kelp browser ask`).
    enum Holder: Equatable, Sendable {
        case agent, user
        case asked(String)
    }
    struct Page: Equatable {
        var session: String, subagent: String?
        /// The workspace and the tab it's in.
        var workspace: String, tab: String
        var title = "", url = ""
        /// The colour its pointer has: the agent's, made to stand out on a page.
        var color: NSColor = .systemPurple
        /// The last few things done there, oldest first.
        var steps: [Step] = []
        /// What the page reported as errors since it was opened: how many, and the last.
        var errors = 0, lastError: String?
        var holder: Holder = .agent
        init(session: String, subagent: String?, workspace: String, tab: String) {
            self.session = session
            self.subagent = subagent
            self.workspace = workspace
            self.tab = tab
        }
    }

    /// By page id (one for each web view an agent drives).
    private(set) var pages: [String: Page] = [:]
    /// The pages that acted in the last `litFor` seconds.
    private(set) var lit: Set<String> = []
    /// The page `kelp browser` last drove in each workspace (a tab id): its next command goes to the same one.
    @ObservationIgnored var browsed: [String: String] = [:]
    @ObservationIgnored private var handles: [String: WeakPage] = [:]
    @ObservationIgnored private var dimming: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    // MARK: told by the browser

    /// `id` is driven now, as `page` says; `handle` gives its picture and takes the user's buttons.
    func drives(_ id: String, _ page: Page, handle: BrowserTab) {
        handles[id] = WeakPage(page: handle)
        if pages[id] != page { pages[id] = page }
    }

    func change(_ id: String, _ edit: (inout Page) -> Void) {
        guard var page = pages[id] else { return }
        edit(&page)
        if pages[id] != page { pages[id] = page }
    }

    /// An action done there: the last step, and the page lit for `litFor`.
    func acted(_ id: String, _ step: String) {
        change(id) { page in
            page.steps.append(Step(step))
            if page.steps.count > Self.keptSteps { page.steps.removeFirst(page.steps.count - Self.keptSteps) }
        }
        lit.insert(id)
        dimming[id]?.cancel()
        dimming[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.litFor)) } catch { return }   // a newer action lights it again
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

    /// A session's pages, its own first, then its subagents' by when they last acted.
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

    /// What a session's row shows: nil without a page; lit while one acted lately; who has it when that's the user.
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

    /// The glow on a tab while what's in it acted lately: its agent's colour.
    func glow(tab: String) -> NSColor? {
        of(tab: tab).first { lit.contains($0.id) }?.page.color
    }

    /// What the tabs of `workspace` show of their pages, for their strip to follow: tab, session, lit.
    func tabMarks(workspace: String) -> [String] {
        pages.filter { $0.value.workspace == workspace }.map {
            "\($0.value.tab) \($0.value.session) \(lit.contains($0.key))"
        }.sorted()
    }

    func handle(_ id: String) -> BrowserTab? { handles[id]?.page }

    /// The page's group comes up, the page in front.
    func show(_ id: String) {
        guard let page = pages[id] else { return }
        app.workbench.show(workspace: page.workspace)
        guard let tab = app.workbench.loadedTabs(page.workspace)?.first(where: { $0.id == page.tab }) else { return }
        app.workbench.open(tab.uri, workspace: page.workspace, focus: false)
        handle(id)?.bringForward()
    }
}

private struct WeakPage {
    weak var page: BrowserTab?
}
