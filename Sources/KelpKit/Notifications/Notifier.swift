import Agents
import AppKit
import Core
import DesignKit
@preconcurrency import UserNotifications   // its center and settings aren't marked Sendable

/// Banner + dock badge when an agent finishes or waits; clicking opens the right pane.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// macOS lets Kelp show banners (false: they're off in System Settings).
    var allowed = true
    let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? .current() : nil   // needs an app bundle
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init()
    }

    func start() {
        center?.delegate = self
        // A permission request can be answered from the banner itself, and an agent at its prompt told what to do next.
        center?.setNotificationCategories([
            UNNotificationCategory(
                identifier: "permission",
                actions: [
                    UNNotificationAction(identifier: "allow", title: String(localized: "Allow")),
                    UNNotificationAction(identifier: "deny", title: String(localized: "Deny"), options: [.destructive])
                ], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: "reply",
                actions: [
                    UNTextInputNotificationAction(
                        identifier: "reply", title: String(localized: "Reply"),
                        textInputButtonTitle: String(localized: "Send"),
                        textInputPlaceholder: String(localized: "Message to the agent")),
                    UNNotificationAction(identifier: "goOn", title: QuickReply.goOn.title)
                ], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: "limitReset",
                actions: [
                    UNNotificationAction(identifier: "continue", title: String(localized: "Continue"))
                ], intentIdentifiers: [])
        ])
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in self.checkAllowed() }
        }
        track(owner: self) { [app] in
            app.sessions
        } changed: { [weak self] _ in
            self?.updateBadge()
        }
        // For as long as Kelp runs: what shows the limits comes and goes (a hidden sidebar), and their warnings mustn't
        // (the built-in that gives them hears each reading, `Contributions.pushed`), nor the Dock's usage face.
        app.watch(.limits)
        // Typing: a key in one of Kelp's windows while it is the key one (a bare modifier isn't a keyDown).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.window?.isKeyWindow == true { self?.lastKey = Date() }
            return e
        }
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] _ in
            self?.releaseHeld()
        }
        track(owner: self) { [app] in
            app.workbench.focusedTab
        } changed: { [weak self] _ in
            self?.lookedAt()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookedAt() }   // queue: .main
        }
        track(owner: self) { [app] in
            app.latest(RoutinesEvent.self)?.runs.filter { $0.outcome == .missed }.map(\.id) ?? []
        } changed: { [weak self] _ in
            self?.missedRuns()
        }
    }

    /// A routine that didn't run (the Mac slept or Kelp was off, and it skips those): a banner that opens its routines.
    /// The ones already there when Kelp opened aren't news.
    private var missedTold: Set<String>?
    private func missedRuns() {
        guard let event = app.latest(RoutinesEvent.self) else { return }
        let missed = event.runs.filter { $0.outcome == .missed }
        defer { missedTold = (missedTold ?? []).union(missed.map(\.id)) }
        guard let told = missedTold else { return }
        for run in missed where !told.contains(run.id) {
            guard let routine = event.routines.first(where: { $0.id == run.routineId }) else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(
                localized: "\(routine.name) didn't run at \(run.due.formatted(date: .omitted, time: .shortened))")
            content.body = String(
                localized: "The Mac was asleep or Kelp wasn't running. Run Now is on its Routines tab.")
            content.userInfo = ["uri": "routines:\(routine.repoId)"]
            alert { [self] in
                center?.add(UNNotificationRequest(identifier: "missed-\(run.id)", content: content, trigger: nil))
                if !allowed, NSApp.isActive { Banner.show(content.body, title: content.title) }
            }
        }
    }

    // MARK: Held while you type (TypingHold)

    private var lastKey: Date?
    private var held: [Session] = []   // finished / failed agents, latest status each
    private var heldAlerts: [() -> Void] = []   // limit warnings, posted as they were
    private var quietWait: Task<Void, Never>?

    private func holds(question: Bool) -> Bool {
        app.settings[SettingKeys.holdBanners]
            && TypingHold.holds(question: question, lastKey: lastKey, active: NSApp.isActive)
    }

    /// A limit warning now, or once typing stops.
    private func alert(_ post: @escaping () -> Void) {
        guard holds(question: false) else {
            post()
            return
        }
        heldAlerts.append(post)
        waitForQuiet()
    }

    private func waitForQuiet() {
        guard quietWait == nil else { return }
        quietWait = Task { [weak self] in
            while let left = self?.lastKey.map({ $0.timeIntervalSinceNow + TypingHold.quiet }), left > 0 {
                do { try await Task.sleep(for: .seconds(left)) } catch { return }
            }
            self?.releaseHeld()
        }
    }

    /// 20 s without a key, Kelp went to the back, or another workspace came up: what waited goes out, the agents in one banner.
    func releaseHeld() {
        quietWait?.cancel()
        quietWait = nil
        let alerts = heldAlerts
        heldAlerts = []
        alerts.forEach { $0() }
        // As each is now: one looked at, or that moved on (answered, at work again), has nothing left to say.
        let ready = held.filter { session in
            app.session(session.id)?.status == session.status
                && !(NSApp.isActive && app.workbench.isViewing(session: session.id))
                && !Mutes.isMuted(session, in: app)
        }
        held = []
        if ready.count == 1 { post(ready[0], holding: false) } else if ready.count > 1 { postHeld(ready) }
    }

    /// "2 agents finished while you typed": a line each; a click shows the first, the rest are marked in the sidebar.
    private func postHeld(_ ss: [Session]) {
        let app = self.app
        let (title, body) = TypingHold.summary(
            ss.map { session in
                (
                    app.worktree(session.worktreeId)?.displayName ?? app.catalog.displayName(session),
                    session.status == .error, session.summary
                )
            })
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = ss.compactMap { app.projectName(app.worktree($0.worktreeId)?.repoId) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
        content.sound = sound(ss.contains { $0.status == .error } ? .error : .done)   // the failure's, if one failed
        content.userInfo = ["session": ss[0].id, "sessions": ss.map(\.id)]
        if !allowed, NSApp.isActive {
            Banner.show(
                body, action: (String(localized: "Show"), { app.workbench.focus(session: ss[0].id) }), title: title,
                subtitle: content.subtitle)
        }
        center?.add(UNNotificationRequest(identifier: "held-\(ss[0].id)", content: content, trigger: nil))
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// A built-in's notification (`Notifications.notifyUser`): now, or once typing stops; a banner in Kelp when
    /// they're off.
    func postAlert(
        _ id: String, _ content: UNNotificationContent, action: (title: String, run: @MainActor () -> Void)?
    ) {
        alert { [self] in
            center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            if !allowed, NSApp.isActive { Banner.show(content.body, action: action, title: content.title) }
        }
    }

    func updateBadge() {
        // Who waits for an answer, as Needs You's marks say: finished work you haven't opened is no question.
        let count = app.sessions.filter { SidebarCell.wantsYou($0) && SidebarCell.shownStatus($0) != .done }.count
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        clearSeen()
    }

    // MARK: Reminders

    private var reminders: [String: Task<Void, Never>] = [:]   // session → the wait for its question's one reminder

    /// `.continuous`: the Mac's sleep counts, and a question an hour old on waking is reminded of at once.
    private func remind(of s: Session) {
        reminders[s.id]?.cancel()
        reminders[s.id] = nil
        guard s.status == .waiting, s.limitHit == nil,
            let minutes = Int(app.settings[SettingKeys.remindAfter])
        else { return }
        reminders[s.id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(minutes * 60), clock: .continuous) } catch { return }
            self?.reminderDue(s)
        }
    }

    private func reminderDue(_ asked: Session) {
        reminders[asked.id] = nil
        guard QuestionReminder.stillStands(asked, now: app.session(asked.id)), let current = app.session(asked.id),
            !Mutes.isMuted(current, in: app)
        else { return }
        post(current, holding: false, again: true)
    }

    /// Seen with Kelp in front, it needs no reminder: what the question asks stays marked on its row.
    private func lookedAt() {
        guard NSApp.isActive else { return }
        for sid in reminders.keys where app.workbench.isViewing(session: sid) {
            reminders.removeValue(forKey: sid)?.cancel()
        }
    }

    /// Banners already answered (the agent was looked at, or moved on) leave Notification Center, like Messages does.
    private var posted: [String: String] = [:]   // session → request id
    private func clearSeen() {
        let stale = posted.filter { sid, rid in
            guard let session = app.session(sid) else { return true }
            return !session.unread || !rid.hasSuffix(session.status.rawValue)
        }
        guard !stale.isEmpty else { return }
        center?.removeDeliveredNotifications(withIdentifiers: Array(stale.values))
        stale.keys.forEach { posted[$0] = nil }
    }

    /// Each `event.session`, as it comes: a status that changes back within a moment still gets its banner.
    func statusChanged(_ s: Session, _ old: Session?) {
        guard old?.status != s.status, [.done, .waiting, .error].contains(s.status), s.isChat else { return }
        if Self.leftToItsParent(s) { return }
        if s.status == .error, s.continueAt != nil, s.limitHit == nil { return }   // Kelp goes on from it by itself
        // A guess off the screen (the row says so; a banner would claim it), or a parked one, out of the way till it calls.
        if s.status == .done, s.guessed == true || app.arrangement.isParked(s.id) { return }
        let turn = NotifyRule.turn(s, after: old)
        // What the agent itself said with this change (a permission request, an error) beats its last reply.
        if s.status != .done, !s.summary.isEmpty, s.summary != old?.summary {
            tell(s, turn: turn)
            return
        }
        Task { await summarizeThenNotify(s, turn: turn) }
    }

    /// A child that finished: its parent reads it and goes on, and that's the one to tell you. One a plan limit stopped
    /// hasn't finished, and only you can decide what's next.
    static func leftToItsParent(_ s: Session) -> Bool { s.parent != nil && s.status == .done && s.limitHit == nil }

    private var rule: NotifyRule {
        func level(_ setting: Setting<String>) -> NotifyRule.Level {
            NotifyRule.Level(rawValue: app.settings[setting]) ?? NotifyRule.Level(rawValue: setting.fallback) ?? .off
        }
        return NotifyRule(
            finished: level(SettingKeys.onFinish), waiting: level(SettingKeys.onWaiting),
            failed: level(SettingKeys.onError), quietUnder: app.settings[SettingKeys.quietUnder])
    }

    private func tell(_ s: Session, turn: TimeInterval?) {
        if tells(s, turn: turn) { post(s) }
    }

    /// A banner comes for this change: the rule for its status and length, and the row isn't muted.
    private func tells(_ s: Session, turn: TimeInterval?) -> Bool {
        // A limit stops the turn with a question in it, what next: it comes as one, however short the turn.
        rule.level(s.limitHit == nil ? s.status : .waiting, turn: turn) != .off && !Mutes.isMuted(s, in: app)
    }

    /// On the notification itself, not NSSound: Focus and Kelp's "Play sound" switch in System Settings silence it.
    private func sound(_ status: AgentStatus) -> UNNotificationSound? {
        guard rule.level(status, turn: nil) == .sound else { return nil }
        return UNNotificationSound(
            named: UNNotificationSoundName(status == .waiting ? "Ping" : status == .error ? "Basso" : "Glass"))
    }

    /// One-line summary for the banner and sidebar from the agent's own last reply, then the notification.
    private func summarizeThenNotify(_ session: Session, turn: TimeInterval?) async {
        var session = session
        // Claude Code: its own last reply (the terminal around it — spinners, mode lines — reads as nonsense when summarized).
        // The Stop hook can come a moment before the transcript has the final message.
        try? await Task.sleep(for: .milliseconds(1200))
        // Nobody at the Mac: a recap from a fork of its conversation (what it did, what's left) waits for whoever comes back.
        // Only for a banner that will show: a recap is a run of Claude, not worth it for a muted row or a short turn.
        if session.status == .done, app.catalog.manifest(session.agent)?.transcript == .claude,
            app.settings[SettingKeys.recap],
            !Presence.here(),
            tells(session, turn: turn),
            let line = await app.quiet(SessionRecap(id: session.id)) ?? nil
        {
            // Up to a minute and a half later: a turn begun meanwhile isn't done, and gets no "Done" banner.
            guard app.session(session.id)?.status == .done else { return }
            session.summary = line
        } else if let reply = await app.quiet(SessionLastReply(id: session.id)) ?? nil {
            let line = Self.firstSentence(reply)
            session.summary = line
            _ = await app.quiet(SessionAnnotate(id: session.id, summary: line, ifStatus: session.status.rawValue))
        }
        tell(session, turn: turn)   // other agents: no summary; the state says enough
    }

    /// "I added `mul(a, b)` to `calc.py`. It returns…" → "Added mul(a, b) to calc.py".
    static func firstSentence(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
        let line = plain.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        // A sentence ends at . ! or ? followed by a space or the end: the dot in "calc.py" doesn't end it.
        let end =
            line.indices.first { index in
                let next = line.index(after: index)
                return ".!?".contains(line[index]) && (next == line.endIndex || line[next].isWhitespace)
            }.map { line.index(after: $0) } ?? line.endIndex
        var sentence = String(line[..<end]).trimmingCharacters(in: .whitespaces)
        if sentence.hasSuffix(".") { sentence.removeLast() }
        for lead in ["I've ", "I have ", "I "] where sentence.hasPrefix(lead) {
            sentence = String(sentence.dropFirst(lead.count))
            sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
            break
        }
        return sentence.count > 90 ? String(sentence.prefix(89)) + "…" : sentence
    }

    /// `again`: the one reminder of a question, in place of its banner.
    private func post(_ s: Session, holding: Bool = true, again: Bool = false) {
        let app = self.app
        // No banner if the user is already looking at that pane (what it asks stays marked until it's answered).
        if NSApp.isActive, app.workbench.isViewing(session: s.id) { return }
        if holding, holds(question: s.status == .waiting || s.limitHit != nil) {
            held.removeAll { $0.id == s.id }
            held.append(s)
            waitForQuiet()
            return
        }
        let model = app, wt = model.worktree(s.worktreeId)
        let content = UNMutableNotificationContent()
        let name = app.catalog.displayName(s), plans = app.extensions.all.plans
        content.title =
            (s.limitHit == nil ? nil : plans?.title(name, s))
            ?? name
            + (again
                ? String(localized: " still needs you")
                : s.status == .waiting
                    ? String(localized: " needs you")
                    : s.status == .error ? String(localized: " ran into an error") : String(localized: " finished"))
        content.subtitle = [model.groupName(wt), model.projectName(wt?.repoId)].compactMap { $0 }.joined(
            separator: " · ")   // as its Needs You row
        content.body =
            s.limitHit.flatMap { plans?.banner($0) }
            ?? (s.summary.isEmpty
                ? (s.status == .waiting
                    ? String(localized: "Waiting for your answer")
                    : String(localized: "Ready for review")) : s.summary)
        content.sound = sound(s.limitHit == nil ? s.status : .waiting)
        content.userInfo = ["session": s.id, "question": s.summary]
        if let cat = Self.category(s) { content.categoryIdentifier = cat }
        if !allowed, NSApp.isActive {   // banners are off: say it inside Kelp instead
            Banner.show(
                content.body, action: (String(localized: "Show"), { app.workbench.focus(session: s.id) }),
                title: content.title, subtitle: content.subtitle, icon: app.catalog.icon(s.agent, size: 24))
        }
        // Under an id of its own: macOS may show one added again under the same id silently.
        let rid = again ? "\(s.id)-again-\(s.status.rawValue)" : "\(s.id)-\(s.status.rawValue)"
        if again, let first = posted[s.id] { center?.removeDeliveredNotifications(withIdentifiers: [first]) }
        center?.add(UNNotificationRequest(identifier: rid, content: content, trigger: nil))
        posted[s.id] = rid
        NSApp.requestUserAttention(.informationalRequest)
        if !again { remind(of: s) }
    }
}
