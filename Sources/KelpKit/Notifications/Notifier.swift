import Agents
import AppKit
import Core
import DesignKit
@preconcurrency import UserNotifications   // the notification center and its settings aren't marked Sendable

/// Posts a banner and sets the Dock badge when an agent finishes or waits; clicking the banner opens the agent's pane.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Whether macOS lets Kelp show banners (false when they're turned off in System Settings).
    var allowed = true
    let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? .current() : nil   // needs an app bundle
    let app: AppModel
    /// The banner category for several sessions: Continue tells each session to go on (`notifyUser`'s `goingOn`).
    static let goOnCategory = "continueAll"
    init(app: AppModel) {
        self.app = app
        super.init()
    }

    func start() {
        center?.delegate = self
        // The user can answer a permission request from the banner itself, and tell an agent at its prompt what to do.
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
                identifier: Self.goOnCategory,
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
        // Watch the limits for as long as Kelp runs. The views that show them come and go (the sidebar can be hidden),
        // but the limit warnings must not stop, and neither must the usage face on the Dock icon. The built-in that
        // posts the warnings hears each reading through `Contributions.pushed`.
        app.watch(.limits)
        // Typing is a key pressed in a Kelp window while that window is key (a bare modifier isn't a keyDown).
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
        activated = NotificationCenter.default.addObserver(
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

    /// Observes Kelp coming forward, when what is on screen counts as looked at. The observer ends with this notifier,
    /// because a test's app makes its own notifier.
    private var activated: NSObjectProtocol?
    isolated deinit { activated.map(NotificationCenter.default.removeObserver) }

    /// Posts a banner for each routine run that didn't happen because the Mac slept or Kelp was off (routines skip such
    /// runs). The banner opens the project's routines. Missed runs already listed when Kelp opened aren't news.
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
            alert { [self] in deliver("missed-\(run.id)", content) }
        }
    }

    // MARK: Held while you type (TypingHold)

    private var lastKey: Date?
    private var held: [Session] = []   // finished or failed agents, each with its latest status
    private var heldAlerts: [() -> Void] = []   // limit warnings, posted as they were made
    private var quietWait: Task<Void, Never>?

    private func holds(question: Bool) -> Bool {
        app.settings[SettingKeys.holdBanners]
            && TypingHold.holds(question: question, lastKey: lastKey, active: NSApp.isActive)
    }

    /// Posts a limit warning now, or once typing stops.
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

    /// Posts what was held, the agents in one banner, after 20 s with no key, when Kelp goes back or a workspace opens.
    func releaseHeld() {
        quietWait?.cancel()
        quietWait = nil
        let alerts = heldAlerts
        heldAlerts = []
        alerts.forEach { $0() }
        // A held agent the user looked at, or one that moved on (answered, working again), needs no banner.
        let ready = held.filter { session in
            app.session(session.id)?.status == session.status
                && !(NSApp.isActive && app.workbench.isViewing(session: session.id))
                && !Mutes.isMuted(session, in: app)
        }
        held = []
        if ready.count == 1 { post(ready[0], holding: false) } else if ready.count > 1 { postHeld(ready) }
    }

    /// Posts one banner for the held agents ("2 agents finished while you typed") with a line for each. A click shows
    /// the first agent; the others stay marked in the sidebar.
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
        content.sound = sound(ss.contains { $0.status == .error } ? .error : .done)   // the failure sound if one failed
        content.userInfo = ["session": ss[0].id, "sessions": ss.map(\.id)]
        let first = ss[0].id
        deliver("held-\(first)", content, action: (String(localized: "Show"), { app.workbench.focus(session: first) }))
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Posts a built-in's notification (`Notifications.notifyUser`) now, or once typing stops.
    func postAlert(
        _ id: String, _ content: UNNotificationContent, action: (title: String, run: @MainActor () -> Void)?
    ) {
        alert { [self] in deliver(id, content, action: action) }
    }

    /// Posts to Notification Center, and as a banner inside Kelp when Kelp is in front with its notifications off.
    private func deliver(
        _ id: String, _ content: UNNotificationContent, action: (title: String, run: @MainActor () -> Void)? = nil,
        icon: NSImage? = nil
    ) {
        if !allowed, NSApp.isActive {
            Banner.show(content.body, action: action, title: content.title, subtitle: content.subtitle, icon: icon)
        }
        center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func updateBadge() {
        // Count agents that wait for an answer, as the Needs You marks do; unopened finished work isn't a question.
        let count = app.sessions.filter { $0.wantsYou && $0.shownStatus != .done }.count
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        clearSeen()
    }

    // MARK: Reminders

    private var reminders: [String: Task<Void, Never>] = [:]   // session id → wait for its one reminder

    /// Schedules the one reminder of a session's question. The `.continuous` clock counts the Mac's sleep, so a
    /// question that is an hour old on waking is reminded of at once.
    private func remind(of session: Session) {
        reminders[session.id]?.cancel()
        reminders[session.id] = nil
        guard session.status == .waiting, session.limitHit == nil,
            let minutes = Int(app.settings[SettingKeys.remindAfter])
        else { return }
        reminders[session.id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(minutes * 60), clock: .continuous) } catch { return }
            self?.reminderDue(session)
        }
    }

    private func reminderDue(_ asked: Session) {
        reminders[asked.id] = nil
        guard QuestionReminder.stillStands(asked, now: app.session(asked.id)), let current = app.session(asked.id),
            !Mutes.isMuted(current, in: app)
        else { return }
        post(current, holding: false, again: true)
    }

    /// Cancels reminders of questions the user looks at with Kelp in front; each question stays marked on its row.
    private func lookedAt() {
        guard NSApp.isActive else { return }
        for sid in reminders.keys where app.workbench.isViewing(session: sid) {
            reminders.removeValue(forKey: sid)?.cancel()
        }
    }

    /// Removes answered banners (the agent was seen or moved on) from Notification Center, as Messages does.
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

    /// Called per `event.session` as it arrives, so a status that changes back within a moment still gets a banner.
    func statusChanged(_ session: Session, _ old: Session?) {
        guard old?.status != session.status, [.done, .waiting, .error].contains(session.status), session.isChat else {
            return
        }
        if Self.leftToItsParent(session) { return }
        // Kelp continues this failed session by itself, so it gets no banner.
        if session.status == .error, session.continueAt != nil, session.limitHit == nil { return }
        // No banner for a done status guessed from the screen (the row says it's a guess; a banner would claim it), or
        // for a parked session, which stays out of the way until it asks for something.
        if session.status == .done, session.guessed == true || app.arrangement.isParked(session.id) { return }
        let turn = NotifyRule.turn(session, after: old)
        // What the agent said with this change (a permission request, an error) is shown instead of its last reply.
        if session.status != .done, !session.summary.isEmpty, session.summary != old?.summary {
            tell(session, turn: turn)
            return
        }
        Task { await summarizeThenNotify(session, turn: turn) }
    }

    /// Whether a finished subagent is left to its parent, which reads the result and goes on; the parent is the one
    /// that tells you. A subagent that a plan limit stopped hasn't finished, and only you can decide what's next.
    static func leftToItsParent(_ session: Session) -> Bool {
        session.parent != nil && session.status == .done && session.limitHit == nil
    }

    private var rule: NotifyRule {
        func level(_ setting: Setting<String>) -> NotifyRule.Level {
            NotifyRule.Level(rawValue: app.settings[setting]) ?? NotifyRule.Level(rawValue: setting.fallback) ?? .off
        }
        return NotifyRule(
            finished: level(SettingKeys.onFinish), waiting: level(SettingKeys.onWaiting),
            failed: level(SettingKeys.onError), quietUnder: app.settings[SettingKeys.quietUnder])
    }

    private func tell(_ session: Session, turn: TimeInterval?) {
        if tells(session, turn: turn) { post(session) }
    }

    /// Whether the change gets a banner: the rule allows its status and turn length, and the row isn't muted.
    private func tells(_ session: Session, turn: TimeInterval?) -> Bool {
        // A limit stops the turn with a question (what next?), so it is told as a question, however short the turn.
        rule.level(session.limitHit == nil ? session.status : .waiting, turn: turn) != .off
            && !Mutes.isMuted(session, in: app)
    }

    /// The sound is on the notification, not NSSound, so Focus and Kelp's "Play sound" in System Settings mute it.
    private func sound(_ status: AgentStatus) -> UNNotificationSound? {
        guard rule.level(status, turn: nil) == .sound else { return nil }
        return UNNotificationSound(
            named: UNNotificationSoundName(status == .waiting ? "Ping" : status == .error ? "Basso" : "Glass"))
    }

    /// Makes a one-line summary for the banner and sidebar from the agent's last reply, then posts the notification.
    private func summarizeThenNotify(_ session: Session, turn: TimeInterval?) async {
        var session = session
        // For Claude Code, use its own last reply, because the terminal text around it (spinners, mode lines) reads as
        // nonsense when summarized. Wait first: the Stop hook can come before the transcript has the final message.
        try? await Task.sleep(for: .milliseconds(1200))
        // When nobody is at the Mac, a recap made from a fork of the conversation (what it did, what's left) waits for
        // whoever comes back. It is made only for a banner that will show, because a recap is a run of Claude and isn't
        // worth it for a muted row or a short turn.
        if session.status == .done, app.catalog.manifest(session.agent)?.transcript == .claude,
            app.settings[SettingKeys.recap],
            !Presence.here(),
            tells(session, turn: turn),
            let line = await app.quiet(SessionRecap(id: session.id), timeout: SessionRecap.timeout ?? 30) ?? nil
        {
            // The recap can come up to a minute and a half later. A turn that began meanwhile isn't done, so it gets
            // no "Done" banner.
            guard app.session(session.id)?.status == .done else { return }
            session.summary = line
        } else if let reply = await app.quiet(SessionLastReply(id: session.id)) ?? nil {
            let line = Self.firstSentence(reply)
            session.summary = line
            _ = await app.quiet(SessionAnnotate(id: session.id, summary: line, ifStatus: session.status.rawValue))
        }
        tell(session, turn: turn)   // an agent with no reply to read gets no summary; its status says enough
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

    /// Posts the banner for a session's new status, or with `again` the one reminder of a question.
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
            separator: " · ")   // as on the agent's Needs You row
        content.body =
            s.limitHit.flatMap { plans?.banner($0) }
            ?? (s.summary.isEmpty
                ? (s.status == .waiting
                    ? String(localized: "Waiting for your answer")
                    : String(localized: "Ready for review")) : s.summary)
        content.sound = sound(s.limitHit == nil ? s.status : .waiting)
        content.userInfo = ["session": s.id, "question": s.summary]
        if let cat = Self.category(s) { content.categoryIdentifier = cat }
        // Each banner gets its own id, because macOS may silently show a notification added again under the same id.
        let rid = again ? "\(s.id)-again-\(s.status.rawValue)" : "\(s.id)-\(s.status.rawValue)"
        if again, let first = posted[s.id] { center?.removeDeliveredNotifications(withIdentifiers: [first]) }
        deliver(
            rid, content, action: (String(localized: "Show"), { app.workbench.focus(session: s.id) }),
            icon: app.catalog.icon(s.agent, size: 24))
        posted[s.id] = rid
        NSApp.requestUserAttention(.informationalRequest)
        if !again { remind(of: s) }
    }
}
