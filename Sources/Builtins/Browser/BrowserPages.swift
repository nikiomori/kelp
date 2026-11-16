// An agent's subagents in the browser: a page each, in the tab of the agent's page, and a row of them to switch between.
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The pages of one agent page's tab (`BrowserTab.pageSet`): its own, the first to drive it (the agent, or the subagent
/// that opened it); and one for each other that opens a page (`kelp browser open` from a subagent), made then. A row of
/// them over the page, each saying who drives it and what it did last, switches; a subagent's page goes when the
/// subagent ends. Words, not pictures: a picture small enough for the row said nothing, and would be taken all along.
@MainActor
@Observable
final class PageSet {
    @ObservationIgnored unowned let host: BrowserTab
    /// Whose the tab's own page is: the subagent, or "" for the agent, that drove it first.
    @ObservationIgnored var owner: String?
    /// The others' pages, by who drives them, in the order they came.
    private(set) var pages: [(who: String, tab: BrowserTab)] = []
    /// The page on show: one of `pages`, or nil for the tab's own.
    private(set) var shown: String?
    @ObservationIgnored private let row = NSStackView()
    /// A pill each, by who drives its page: the tab's own page's under its `owner`, which no other page has.
    @ObservationIgnored private(set) var pills: [String: PointerButton] = [:]
    @ObservationIgnored private var following = false

    init(host: BrowserTab) {
        self.host = host
        row.orientation = .horizontal
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(
            top: Metrics.lineGap, left: Metrics.gap, bottom: Metrics.lineGap, right: Metrics.gap)
        row.alignment = .centerY
        host.switchSlot.pin(row)
    }

    /// The page `args` is for, when it isn't the tab's own: a subagent's, made for its `open`. Nil: the tab's own.
    func route(_ action: BrowserAction, _ args: JSONValue) -> BrowserTab? {
        let who = args["subagent"]?.string ?? ""
        guard let owner else {
            self.owner = who
            return nil
        }
        if who == owner { return nil }
        if let page = pages.first(where: { $0.who == who })?.tab { return page }
        guard action == .open else { return nil }   // reading or clicking before it opened one: the page it shares
        let page = BrowserTab(uri: TabURI.agentPage("about:blank"), app: host.app)
        page.host = host
        page.watch()
        pages.append((who, page))
        follow(args["session"]?.string)
        showRow()
        show(who)
        return page
    }

    /// After an action on one of the set's pages: its words in the row.
    func acted(_ page: BrowserTab) {
        if !pages.isEmpty { showRow() }
    }

    /// The page in front: `who`'s, or the tab's own (nil).
    func show(_ who: String?) {
        shown = pages.contains { $0.who == who } ? who : nil
        for (key, page) in pages {
            page.view.isHidden = key != shown
            if key == shown, page.view.superview == nil { host.pageArea.pin(page.view) }
        }
        host.ownContent.isHidden = shown != nil
        showRow()
    }

    /// The page on show, for ⌘R and ⌘F.
    var shownTab: BrowserTab { pages.first { $0.who == shown }?.tab ?? host }

    /// Its subagents' pages go as they end (and all of them with the turn).
    private func follow(_ session: String?) {
        guard !following, let session else { return }
        following = true
        track(owner: self) { [app = host.app] in
            app.session(session)?.runningSubagents.map(\.id) ?? []
        } changed: { [weak self] running in
            self?.drop { !running.contains($0) && !$0.isEmpty }
        }
    }

    private func drop(_ ended: (String) -> Bool) {
        let gone = pages.filter { ended($0.who) }
        guard !gone.isEmpty else { return }
        pages.removeAll { ended($0.who) }
        for (who, page) in gone {
            page.view.removeFromSuperview()
            pills.removeValue(forKey: who)?.removeFromSuperview()
            Task { _ = await page.close() }
        }
        show(pages.contains { $0.who == shown } ? shown : nil)
    }

    /// The row: a pill for each page, who drives it and what it did last, the one on show filled.
    private func showRow() {
        host.switchHeight.isActive = pages.isEmpty
        // The agent's own page ("") is one of `pages` when a subagent drove the tab first: keyed by its owner, the
        // tab's own pill isn't the agent's.
        let all = [(owner ?? "", host, true)] + pages.map { ($0.who, $0.tab, false) }
        for (index, (who, page, own)) in all.enumerated() {
            let pill = pills[who] ?? makePill(who, own: own)
            if pill.superview == nil { row.insertArrangedSubview(pill, at: min(index, row.arrangedSubviews.count)) }
            pill.title = name(who, page)
            pill.restFill = (own ? nil : who) == shown ? .fillSelected : .fillRest
        }
    }

    private func makePill(_ who: String, own: Bool) -> PointerButton {
        let pill = PointerButton(title: "") { [weak self] in self?.show(own ? nil : who) }
        pill.padding = Metrics.gap
        pill.font = .ui(TextSize.caption)
        pill.lineBreakMode = .byTruncatingTail
        pills[who] = pill
        return pill
    }

    /// `mobile · clicks “Pay now”`: who drives it (a subagent by what it was asked, the agent by name) and its last step.
    private func name(_ who: String, _ page: BrowserTab) -> String {
        let whose = page.driverName(who)
        let step = page.drive?.lastStep
        return [String(whose.prefix(28)), step.map { String($0.prefix(28)) }].compactMap { $0 }.joined(separator: " · ")
    }
}
