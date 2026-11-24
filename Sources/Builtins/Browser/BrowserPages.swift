// How an agent's subagents use the browser: each gets a page in the tab of the agent's page, and a row of pills over
// the page switches between them.
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The pages in the tab of one agent's page (`BrowserTab.pageSet`). The tab's own page belongs to whoever drove it
/// first (the agent, or the subagent that opened it). Each other agent or subagent that opens a page (a subagent's
/// `kelp browser open`) gets one, made at that moment. A row of pills over the page switches between them, each
/// saying who drives the page and what it did last. A subagent's page goes when the subagent ends. The pills show
/// words, not pictures, because a picture small enough for the row said nothing and would have to be taken all along.
@MainActor
@Observable
final class PageSet {
    @ObservationIgnored unowned let host: BrowserTab
    /// Who owns the tab's own page: the subagent that drove it first, or "" when the agent did.
    @ObservationIgnored var owner: String?
    /// The pages of everyone else, by who drives them, in the order they came.
    private(set) var pages: [(who: String, tab: BrowserTab)] = []
    /// Who drives the page on show: one of `pages`, or nil for the tab's own page.
    private(set) var shown: String?
    @ObservationIgnored private let row = NSStackView()
    /// The fill under the pill of the page on show: one, moving from pill to pill as a segmented control's does.
    @ObservationIgnored private let chosen = FillStack()
    /// One pill for each page, by who drives the page. The pill of the tab's own page is under its `owner`, which no
    /// other page has.
    @ObservationIgnored private(set) var pills: [String: PointerButton] = [:]
    @ObservationIgnored private var following = false

    init(host: BrowserTab) {
        self.host = host
        row.orientation = .horizontal
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(
            top: Metrics.lineGap, left: Metrics.gap, bottom: Metrics.lineGap, right: Metrics.gap)
        row.alignment = .centerY
        host.switchSlot.pinBottom(row)
        chosen.fill = .fillSelected
        chosen.layer?.cornerRadius = Metrics.radiusSM
        chosen.layer?.cornerCurve = .continuous
        chosen.isHidden = true
        row.addSubview(chosen, positioned: .below, relativeTo: nil)   // not arranged: it sits under the pills
    }

    /// Returns the page that `args` is for when it isn't the tab's own page. That is a subagent's page, made for the
    /// subagent's `open`. Nil means the tab's own page.
    func route(_ action: BrowserAction, _ args: JSONValue) -> BrowserTab? {
        let who = args["subagent"]?.string ?? ""
        guard let owner else {
            self.owner = who
            return nil
        }
        if who == owner { return nil }
        if let page = pages.first(where: { $0.who == who })?.tab { return page }
        guard action == .open else { return nil }   // before its own open, a subagent uses the shared page
        let page = BrowserTab(uri: TabURI.agentPage("about:blank"), app: host.app)
        page.host = host
        page.watch()
        pages.append((who, page))
        follow(args["session"]?.string)
        showRow()
        show(who)
        return page
    }

    /// Updates the words in the row after an action on one of the set's pages.
    func acted() {
        if !pages.isEmpty { showRow() }
    }

    /// Brings a page to the front: the page `who` drives, or the tab's own page for nil.
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

    /// Closes each subagent's page as the subagent ends, and all of them when the turn ends.
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
        // A pill that goes fades where it stood, and the pills after it move up to its place rather than jump there.
        let places = row.arrangedSubviews.map { ($0, $0.placeInWindow) }
        for (who, page) in gone {
            page.view.removeFromSuperview()
            let pill = pills.removeValue(forKey: who)
            pill?.leaveGhost(in: row, duration: Motion.fast)   // it goes in two thirds of the time it came in
            pill?.removeFromSuperview()
            Task { _ = await page.close() }
        }
        row.layoutSubtreeIfNeeded()
        for (pill, place) in places where pill.superview != nil { pill.slide(from: place, duration: Motion.base) }
        show(pages.contains { $0.who == shown } ? shown : nil)
    }

    /// Updates the row: a pill for each page that says who drives it and what it did last, with the pill of the page on
    /// show on the one chosen fill, which moves to it (`moveChosen`). The row slides in over the page with
    /// the first subagent's page and out with the last; a new pill fades in.
    private func showRow() {
        defer { host.switchSlot.reveal(host.switchHeight, open: !pages.isEmpty) }
        // When a subagent drove the tab first, the agent's own page ("") is among `pages`. Because pages are keyed by
        // who drives them, the pill of the tab's own page then isn't the agent's.
        let all = [(owner ?? "", host, true)] + pages.map { ($0.who, $0.tab, false) }
        for (index, (who, page, own)) in all.enumerated() {
            let pill = pills[who] ?? makePill(who, own: own)
            if pill.superview == nil {
                row.insertArrangedSubview(pill, at: min(index, row.arrangedSubviews.count))
                pill.fadeIn(Motion.base)
            }
            pill.title = name(who, page)
            pill.toolTip = pill.title   // the whole of it, when the pill ends in "…"
            pill.restFill = (own ? nil : who) == shown ? nil : .fillRest   // the chosen one is on `chosen`
        }
        moveChosen()
    }

    /// Puts `chosen` under the pill of the page on show, moving there over `Motion.base` (at once the first time).
    private func moveChosen() {
        row.layoutSubtreeIfNeeded()
        guard let pill = pills[shown ?? owner ?? ""], pill.superview === row else { return chosen.isHidden = true }
        let first = chosen.isHidden
        chosen.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = first || row.window == nil ? 0 : Motion.duration(Motion.base)
            ctx.timingFunction = Motion.soft
            chosen.animator().frame = pill.frame
        }
    }

    private func makePill(_ who: String, own: Bool) -> PointerButton {
        let pill = PointerButton(title: "") { [weak self] in self?.show(own ? nil : who) }
        pill.padding = Metrics.gap
        pill.font = .ui(TextSize.caption)
        pill.lineBreakMode = .byTruncatingTail   // a long task or step ends in "…", at a word's edge or not
        pill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pill.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.popoverWidth).isActive = true
        pills[who] = pill
        return pill
    }

    /// Returns a pill's title, such as `mobile · clicks “Pay now”`: who drives the page (a subagent by its task, the
    /// agent by name) and its last step.
    private func name(_ who: String, _ page: BrowserTab) -> String {
        let whose = page.driverName(who)
        let step = page.drive?.lastStep
        return [whose, step].compactMap { $0 }.joined(separator: " · ")
    }
}

extension NSView {
    /// Puts `view` in this slot by its bottom edge, clipped, so as the slot opens (`reveal`) the view comes down out of
    /// the slot's top edge rather than growing.
    func pinBottom(_ view: NSView) {
        clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    /// Opens the slot (`height`) to its view's height, or closes it, so what is under it moves rather than jumps. It
    /// comes over `base` easing out, and goes in about two thirds of that, easing in.
    func reveal(_ height: NSLayoutConstraint, open: Bool) {
        let tall = open ? subviews.first?.fittingSize.height ?? 0 : 0
        guard tall != height.constant else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = window == nil ? 0 : Motion.duration(open ? Motion.base : Motion.fast)
            ctx.timingFunction = CAMediaTimingFunction(name: open ? .easeOut : .easeIn)
            ctx.allowsImplicitAnimation = true
            height.animator().constant = tall
            superview?.layoutSubtreeIfNeeded()
        }
    }
}
