import AppKit
import Core
import DesignKit

extension LimitHit {
    /// When it resets, if that can be told, read from when it stopped: "3pm" stays today's once that has passed.
    var resetAt: Date? { resets.flatMap { ResetTime.parse($0, now: at) } }
}

/// What to say of a session a plan limit stopped, and who could go on with its work.
enum LimitStop {
    struct Taker: Equatable { var id: String, name: String, used: Double? }

    /// The installed agents but this one and those out of plan: the freest first, those without a plan's numbers last.
    static func takers(_ agents: [(id: String, name: String)], except: String?, used: [String: Double]) -> [Taker] {
        let open = agents.filter { $0.id != except && (used[$0.id] ?? 0) < 100 }.map { Taker(id: $0.id, name: $0.name, used: used[$0.id]) }
        return open.enumerated().sorted { a, b in
            (a.element.used ?? 101, a.offset) < (b.element.used ?? 101, b.offset)
        }.map(\.element)
    }

    /// The one the button names: the first with room, else the first without numbers, else the freest there is.
    static func pick(_ takers: [Taker]) -> Taker? {
        takers.first { ($0.used ?? 100) < 90 } ?? takers.first { $0.used == nil } ?? takers.first
    }

    /// A time, with its date unless that's today.
    static func clock(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        d.formatted(date: calendar.isDate(d, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
    }

    /// Its row's second line.
    static func rowLine(_ s: Session, now: Date = Date()) -> (word: String, text: String)? {
        guard let hit = s.limitHit else { return nil }
        if let at = s.continueAt { return (String(localized: "Continues"), String(localized: "at \(clock(at, now: now))")) }
        if let at = hit.resetAt, at <= now { return (String(localized: "Limit:"), String(localized: "has reset")) }
        let resets = hit.resetAt.map { clock($0, now: now) } ?? hit.resets
        return (String(localized: "Limit:"), resets.map { String(localized: "resets \($0)") } ?? hit.kind)
    }

    /// The banner's text: "5-hour · resets 3:40pm".
    static func banner(_ hit: LimitHit) -> String { hit.resets.map { String(localized: "\(hit.kind) · resets \($0)") } ?? hit.kind }

    static func title(_ name: String, _ s: Session, now: Date = Date()) -> String {
        if let at = s.continueAt { return String(localized: "\(name) will continue at \(clock(at, now: now))") }
        if let at = s.limitHit?.resetAt, at <= now { return String(localized: "\(name): the limit has reset") }
        return String(localized: "\(name) hit its \(s.limitHit?.kind ?? "") limit")
    }

    static func detail(_ s: Session, now: Date = Date()) -> String {
        if s.continueAt != nil { return String(localized: "Kelp types “continue” here a minute after the reset, even with its window closed.") }
        guard let at = s.limitHit?.resetAt, at > now else { return String(localized: "The work so far stays in this tab.") }
        return String(localized: "Resets at \(clock(at, now: now)), in \(LimitForecast.duration(at.timeIntervalSince(now))). The work so far stays in this tab.")
    }
}

/// Over the foot of the terminal of an agent a plan limit stopped: go on in another agent, or here at the reset. Over it, not
/// beside it: the TUI keeps its size. ✕ puts it away; the row goes on saying so until the agent does something else.
@MainActor
final class LimitStrip: NSView {
    private let app: AppModel, id: String
    private let title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
    private let handOff = NSComboButton(title: "", menu: NSMenu(), target: nil, action: nil)
    private let later = NSButton(), cancel = NSButton()
    private var taker: String?
    private var dismissed: Date?       // the stop ✕ put away: the next one shows again
    private var watchingPlans = false
    private var clock: Task<Void, Never>?

    init(app: AppModel, session id: String) {
        self.app = app; self.id = id
        super.init(frame: .zero)
        isHidden = true
        build()
        track(owner: self) { [app, id] in app.session(id) } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app] in app.limits } changed: { [weak self] _ in self?.update() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let mark = NSImageView(image: .symbol("clock", String(localized: "Stopped at its limit")))
        mark.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        mark.contentTintColor = .textOrange
        title.font = .ui(13, weight: .semibold)
        detail.font = .ui(11)
        detail.textColor = .secondaryLabelColor
        for l in [title, detail] {
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let words = NSStackView(views: [title, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        handOff.target = self
        handOff.action = #selector(handOffTapped)
        later.bezelStyle = .push
        later.target = self
        later.action = #selector(laterTapped)
        cancel.bezelStyle = .push
        cancel.title = String(localized: "Cancel")
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        let close = IconButton(.symbol("xmark"), tip: String(localized: "Dismiss")) { [weak self] in
            self?.dismissed = self?.app.session(self?.id ?? "")?.limitHit?.at
            self?.update()
        }
        let row = NSStackView(views: [mark, words, handOff, later, cancel, close])
        row.spacing = Metrics.gapWide
        row.detachesHiddenViews = true
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 10)
        // A narrow pane drops the wait first; the words give way before any button.
        row.setVisibilityPriority(.init(rawValue: 300), for: later)
        row.setVisibilityPriority(.init(rawValue: 400), for: handOff)
        let card = FloatingCard(row)
        card.translatesAutoresizingMaskIntoConstraints = false; addSubview(card)
        NSLayoutConstraint.activate([card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    private func update() {
        let now = Date()
        guard window != nil, let s = app.session(id), let hit = s.limitHit, hit.at != dismissed else {
            isHidden = true
            showing(false)
            return
        }
        isHidden = false
        showing(true)
        title.stringValue = LimitStop.title(app.catalog.displayName(s), s, now: now)
        detail.stringValue = LimitStop.detail(s, now: now)
        let reset = hit.resetAt, waiting = s.continueAt != nil, passed = reset.map { $0 <= now } ?? false
        let takers = waiting || RemoteHost.of(s.cwd) != nil ? [] : LimitStop.takers(app.catalog.installed(app.catalog.all).map { ($0.id, $0.name) },
                                                                                    except: s.agent, used: planUse())
        let first = LimitStop.pick(takers)
        taker = first?.id
        handOff.isHidden = first == nil
        handOff.title = first.map { String(localized: "Continue in \($0.name)") } ?? ""
        handOff.menu = menu(takers)
        later.isHidden = waiting || reset == nil
        later.title = passed ? String(localized: "Continue") : reset.map { String(localized: "Continue at \(LimitStop.clock($0, now: now))") } ?? ""
        cancel.isHidden = !waiting
    }

    /// How full each agent's fullest plan limit is.
    private func planUse() -> [String: Double] {
        guard let u = app.limits else { return [:] }
        return LimitAlerts.readings(u).reduce(into: [:]) { $0[$1.agent] = max($0[$1.agent] ?? 0, $1.limit.percent) }
    }

    private func menu(_ takers: [LimitStop.Taker]) -> NSMenu {
        let m = NSMenu()
        for t in takers {
            let i = m.add(t.name) { [weak self] in self?.hand(to: t.id) }
            i.image = app.catalog.icon(t.id)
            if let used = t.used { i.badge = NSMenuItemBadge(string: "\(Int(used.rounded())) %") }
        }
        return m
    }

    /// While it's up: the plans' numbers stay fresh, and "in 38 min" counts down to the reset, which nothing announces.
    private func showing(_ on: Bool) {
        if on != watchingPlans {
            watchingPlans = on
            if on { app.watch(.limits) } else { app.unwatch(.limits) }
        }
        clock?.cancel(); clock = nil
        guard on else { return }
        clock = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.update()
        }
    }

    @objc private func handOffTapped() { if let taker { hand(to: taker) } }
    private func hand(to agent: String) {
        dismissed = app.session(id)?.limitHit?.at
        AgentActions(app).handoff(id, to: agent, full: false, send: true)
        update()
    }

    /// At the reset and a minute more: a turn that goes on by itself has started by then. Past it: now.
    @objc private func laterTapped() {
        guard let reset = app.session(id)?.limitHit?.resetAt else { return }
        let app = app, id = id
        if reset <= Date() {
            Task { await app.call(SessionSend(id: id, text: "continue", enter: true)) }
        } else {
            Task { await app.call(SessionContinueAt(id: id, at: reset.addingTimeInterval(60))) }
        }
    }

    @objc private func cancelTapped() {
        let app = app, id = id
        Task { await app.call(SessionContinueAt(id: id, at: nil)) }
    }
}
