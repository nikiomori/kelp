import AppKit
@preconcurrency import UserNotifications   // its center and settings aren't marked Sendable
import Core

/// Banner + dock badge when an agent finishes or waits; clicking opens the right pane.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// macOS lets Kelp show banners (false: they're off in System Settings).
    private var allowed = true
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? .current() : nil   // needs an app bundle
    private let app: AppModel
    init(app: AppModel) { self.app = app; super.init() }

    func start() {
        center?.delegate = self
        // A permission request can be answered from the banner itself, and an agent at its prompt told what to do next.
        center?.setNotificationCategories([UNNotificationCategory(identifier: "permission", actions: [
            UNNotificationAction(identifier: "allow", title: String(localized: "Allow")),
            UNNotificationAction(identifier: "deny", title: String(localized: "Deny"), options: [.destructive])
        ], intentIdentifiers: []), UNNotificationCategory(identifier: "reply", actions: [
            UNTextInputNotificationAction(identifier: "reply", title: String(localized: "Reply"), textInputButtonTitle: String(localized: "Send"),
                                          textInputPlaceholder: String(localized: "Message to the agent"))
        ], intentIdentifiers: []), UNNotificationCategory(identifier: "limitReset", actions: [
            UNNotificationAction(identifier: "continue", title: String(localized: "Continue"))
        ], intentIdentifiers: [])])
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in Task { @MainActor in self.checkAllowed() } }
        track(owner: self) { [app] in app.sessions } changed: { [weak self] _ in self?.updateBadge() }
        track(owner: self) { [app] in app.limits } changed: { [weak self] u in self?.limitsChanged(u) }
        // Typing: a key in one of Kelp's windows while it is the key one (a bare modifier isn't a keyDown).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.window?.isKeyWindow == true { self?.lastKey = Date() }
            return e
        }
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self] _ in self?.releaseHeld() }
        track(owner: self) { [app] in app.routines?.runs.filter { $0.outcome == .missed }.map(\.id) ?? [] } changed: { [weak self] _ in self?.missedRuns() }
    }

    /// A routine that didn't run (the Mac slept or Kelp was off, and it skips those): a banner that opens its routines.
    /// The ones already there when Kelp opened aren't news.
    private var missedTold: Set<String>?
    private func missedRuns() {
        guard let e = app.routines else { return }
        let missed = e.runs.filter { $0.outcome == .missed }
        defer { missedTold = (missedTold ?? []).union(missed.map(\.id)) }
        guard let told = missedTold else { return }
        for run in missed where !told.contains(run.id) {
            guard let r = e.routines.first(where: { $0.id == run.routineId }) else { continue }
            let c = UNMutableNotificationContent()
            c.title = String(localized: "\(r.name) didn't run at \(run.due.formatted(date: .omitted, time: .shortened))")
            c.body = String(localized: "The Mac was asleep or Kelp wasn't running. Run Now is on its Routines tab.")
            c.userInfo = ["uri": "routines:\(r.repoId)"]
            alert { [self] in
                center?.add(UNNotificationRequest(identifier: "missed-\(run.id)", content: c, trigger: nil))
                if !allowed, NSApp.isActive { Banner.show(c.body, title: c.title) }
            }
        }
    }

    // MARK: Held while you type (TypingHold)

    private var lastKey: Date?
    private var held: [Session] = []                  // finished / failed agents, latest status each
    private var heldAlerts: [() -> Void] = []         // limit warnings, posted as they were
    private var quietWait: Task<Void, Never>?

    private func holds(question: Bool) -> Bool {
        app.settings.bool("agents.holdBanners") ?? true && TypingHold.holds(question: question, lastKey: lastKey, active: NSApp.isActive)
    }

    /// A limit warning now, or once typing stops.
    private func alert(_ post: @escaping () -> Void) {
        guard holds(question: false) else { post(); return }
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
        quietWait?.cancel(); quietWait = nil
        let alerts = heldAlerts; heldAlerts = []
        alerts.forEach { $0() }
        // As each is now: one looked at, or that moved on (answered, at work again), has nothing left to say.
        let ready = held.filter { h in
            app.session(h.id)?.status == h.status && !(NSApp.isActive && app.workbench.isViewing(session: h.id))
        }
        held = []
        if ready.count == 1 { post(ready[0], holding: false) } else if ready.count > 1 { postHeld(ready) }
    }

    /// "2 agents finished while you typed": a line each; a click shows the first, the rest are marked in the sidebar.
    private func postHeld(_ ss: [Session]) {
        let app = self.app
        let (title, body) = TypingHold.summary(ss.map { s in
            (app.worktree(s.worktreeId)?.displayName ?? app.catalog.displayName(s), s.status == .error, s.summary)
        })
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        c.subtitle = ss.compactMap { app.projectName(app.worktree($0.worktreeId)?.repoId) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
        c.sound = sound(ss.contains { $0.status == .error } ? .error : .done)   // the failure's, if one failed
        c.userInfo = ["session": ss[0].id, "sessions": ss.map(\.id)]
        if !allowed, NSApp.isActive {
            Banner.show(body, action: (String(localized: "Show"), { app.workbench.focus(session: ss[0].id) }), title: title, subtitle: c.subtitle)
        }
        center?.add(UNNotificationRequest(identifier: "held-\(ss[0].id)", content: c, trigger: nil))
        NSApp.requestUserAttention(.informationalRequest)
    }

    private var limitAlerts = LimitAlerts()
    private var forecastTold = Set<String>()   // limits already warned about, until they stop filling faster than they reset
    private func limitsChanged(_ u: UsageGet.Result?) {
        guard let u else { return }
        for a in limitAlerts.update(u, first: Int(app.settings.string("usage.alertAt") ?? "80")) {
            let name = app.catalog.all.first { $0.id == a.agent }?.name ?? a.agent
            let c = UNMutableNotificationContent()
            c.title = String(localized: "\(name) is at \(Int(a.percent.rounded())) %")
            c.body = a.resets.map { String(localized: "\(a.kind) · resets \($0)") } ?? a.kind
            c.sound = a.level >= 95 ? .default : nil
            alert { [self] in
                center?.add(UNNotificationRequest(identifier: "limit-\(a.agent)-\(a.kind)-\(a.level)", content: c, trigger: nil))
                if !allowed, NSApp.isActive { Banner.show(c.body, title: c.title) }
            }
        }
        forecastChanged(u)
        resetsChanged(u)
    }

    private var resets = LimitResets()
    private var resetWaits: [String: Task<Void, Never>] = [:]
    private func resetsChanged(_ u: UsageGet.Result) {
        for agent in resets.update(LimitAlerts.readings(u)) {
            guard let until = resets.full[agent]?.until else { continue }
            resetWaits[agent]?.cancel()
            resetWaits[agent] = Task { [weak self] in
                // A minute past it: a turn that goes on by itself at the reset has started by then. The clock counts sleep.
                do { try await Task.sleep(until: .now + .seconds(until.timeIntervalSinceNow + 60), clock: .continuous) } catch { return }
                self?.limitReset(agent)
            }
        }
    }

    /// A limit that stopped sessions reset: a banner whose Continue tells them to go on.
    private func limitReset(_ agent: String) {
        resetWaits[agent] = nil
        guard let f = resets.end(agent) else { return }
        let stopped = LimitResets.stopped(app.sessions, agent: agent, f)
        guard let first = stopped.first else { return }
        let app = self.app, ids = stopped.map(\.id)
        let c = UNMutableNotificationContent()
        let name = app.catalog.all.first { $0.id == agent }?.name ?? agent
        c.title = String(localized: "\(name): the limit has reset")
        c.body = String(localized: "Stopped at it: \(stopped.map(app.catalog.displayName).joined(separator: ", "))")
        c.sound = .default; c.categoryIdentifier = "limitReset"
        c.userInfo = ["session": first.id, "sessions": ids]
        alert { [self] in
            center?.add(UNNotificationRequest(identifier: "reset-\(agent)", content: c, trigger: nil))
            if !allowed, NSApp.isActive { Banner.show(c.body, action: (String(localized: "Continue"), { Self.goOn(app, ids) }), title: c.title) }
        }
    }

    /// "continue" to each that still stands where the limit left it (one the user went on with meanwhile isn't told twice).
    private static func goOn(_ app: AppModel, _ ids: [String]) {
        let still = ids.filter { id in app.session(id).map { [.done, .error].contains($0.status) } ?? false }
        Task { for id in still { _ = await app.call(SessionSend(id: id, text: "continue", enter: true)) } }
    }

    private func forecastChanged(_ u: UsageGet.Result) {
        guard Int(app.settings.string("usage.alertAt") ?? "80") != nil else { return }
        var now = Set<String>()
        for (agent, l, resetAt) in LimitAlerts.readings(u) {
            let key = LimitForecast.key(agent, l.kind)
            guard let eta = app.forecast.warning(key, resetAt: resetAt) else { continue }
            now.insert(key)
            guard forecastTold.insert(key).inserted else { continue }
            let name = app.catalog.all.first { $0.id == agent }?.name ?? agent
            let c = UNMutableNotificationContent()
            c.title = String(localized: "\(name): \(l.kind) limit full in \(LimitForecast.duration(eta))")
            c.body = String(localized: "At this pace it fills before it resets.")
            alert { [self] in
                center?.add(UNNotificationRequest(identifier: "forecast-\(key)", content: c, trigger: nil))
                if !allowed, NSApp.isActive { Banner.show(c.body, title: c.title) }
            }
        }
        forecastTold.formIntersection(now)
    }

    /// macOS can switch Kelp's banners off (System Settings › Notifications): say so once, instead of failing silently.
    /// Called at launch and when Kelp comes to the front.
    func checkAllowed() {
        center?.getNotificationSettings { s in
            let off = s.authorizationStatus == .denied || s.alertSetting == .disabled
            Task { @MainActor in
                self.allowed = !off
                let d = UserDefaults.standard
                guard off else { d.removeObject(forKey: "notifications.warnedOff"); return }
                guard !d.bool(forKey: "notifications.warnedOff") else { return }
                d.set(true, forKey: "notifications.warnedOff")
                Banner.show(String(localized: "Notifications for Kelp are turned off in System Settings, so you won't hear when an agent needs you."), style: .error,
                            action: (String(localized: "Open Settings"), {
                                let id = Bundle.main.bundleIdentifier ?? ""
                                if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                                    NSWorkspace.shared.open(u)
                                }
                            }))
            }
        }
    }

    /// First launch's "Send Test Notification": a banner now, or `false` when macOS has them turned off for Kelp.
    func sendTest(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else { done(false); return }
        Task {
            let s = await center.notificationSettings()
            let off = s.authorizationStatus == .denied || s.alertSetting == .disabled
            if !off {
                let c = UNMutableNotificationContent()
                c.title = String(localized: "Kelp can reach you")
                c.body = String(localized: "This is how you'll hear that an agent finished or needs you."); c.sound = .default
                try? await center.add(UNNotificationRequest(identifier: "kelp-test", content: c, trigger: nil))
            }
            done(!off)
        }
    }

    func updateBadge() {
        // Who waits for an answer, as Needs You's marks say: finished work you haven't opened is no question.
        let n = app.sessions.filter { SidebarCell.wantsYou($0) && SidebarCell.shownStatus($0) != .done }.count
        let label = n > 0 ? "\(n)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        clearSeen()
    }

    /// Banners already answered (the agent was looked at, or moved on) leave Notification Center, like Messages does.
    private var posted: [String: String] = [:]   // session → request id
    private func clearSeen() {
        let stale = posted.filter { sid, rid in
            guard let s = app.session(sid) else { return true }
            return !s.unread || !rid.hasSuffix(s.status.rawValue)
        }
        guard !stale.isEmpty else { return }
        center?.removeDeliveredNotifications(withIdentifiers: Array(stale.values))
        stale.keys.forEach { posted[$0] = nil }
    }

    /// Each `event.session`, as it comes: a status that changes back within a moment still gets its banner.
    func statusChanged(_ s: Session, _ old: Session?) {
        guard old?.status != s.status, [.done, .waiting, .error].contains(s.status), s.agent != "shell" else { return }
        let turn = NotifyRule.turn(s, after: old)
        // What the agent itself said with this change (a permission request, an error) beats its last reply.
        if s.status != .done, !s.summary.isEmpty, s.summary != old?.summary { tell(s, turn: turn); return }
        Task { await summarizeThenNotify(s, turn: turn) }
    }

    private var rule: NotifyRule {
        func level(_ key: String, _ standard: NotifyRule.Level) -> NotifyRule.Level { app.settings.string(key).flatMap(NotifyRule.Level.init) ?? standard }
        return NotifyRule(finished: level("agents.onFinish", .banner), waiting: level("agents.onWaiting", .sound), failed: level("agents.onError", .sound),
                          quietUnder: app.settings.number("agents.quietUnder") ?? 20)
    }

    private func tell(_ s: Session, turn: TimeInterval?) {
        if rule.level(s.status, turn: turn) != .off { post(s) }
    }

    /// On the notification itself, not NSSound: Focus and Kelp's "Play sound" switch in System Settings silence it.
    private func sound(_ status: AgentStatus) -> UNNotificationSound? {
        guard rule.level(status, turn: nil) == .sound else { return nil }
        return UNNotificationSound(named: UNNotificationSoundName(status == .waiting ? "Ping" : status == .error ? "Basso" : "Glass"))
    }

    /// One-line summary for the banner and sidebar from the agent's own last reply, then the notification.
    private func summarizeThenNotify(_ s: Session, turn: TimeInterval?) async {
        var s = s
        // Claude Code: its own last reply (the terminal around it — spinners, mode lines — reads as nonsense when summarized).
        // The Stop hook can come a moment before the transcript has the final message.
        try? await Task.sleep(for: .milliseconds(1200))
        if let reply = await app.quiet(SessionLastReply(id: s.id)) ?? nil {
            let line = Self.firstSentence(reply)
            s.summary = line
            _ = await app.quiet(SessionAnnotate(id: s.id, summary: line))
        }
        tell(s, turn: turn)   // other agents: no summary; the state says enough
    }

    /// "I added `mul(a, b)` to `calc.py`. It returns…" → "Added mul(a, b) to calc.py".
    static func firstSentence(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "`", with: "").split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        // A sentence ends at . ! or ? followed by a space or the end: the dot in "calc.py" doesn't end it.
        let end = line.indices.first { i in
            let next = line.index(after: i)
            return ".!?".contains(line[i]) && (next == line.endIndex || line[next].isWhitespace)
        }.map { line.index(after: $0) } ?? line.endIndex
        var s = String(line[..<end]).trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(".") { s.removeLast() }
        for lead in ["I've ", "I have ", "I "] where s.hasPrefix(lead) {
            s = String(s.dropFirst(lead.count))
            s = s.prefix(1).uppercased() + s.dropFirst()
            break
        }
        return s.count > 90 ? String(s.prefix(89)) + "…" : s
    }

    private func post(_ s: Session, holding: Bool = true) {
        let app = self.app
        // No banner if the user is already looking at that pane (what it asks stays marked until it's answered).
        if NSApp.isActive, app.workbench.isViewing(session: s.id) { return }
        if holding, holds(question: s.status == .waiting) {
            held.removeAll { $0.id == s.id }; held.append(s)
            waitForQuiet()
            return
        }
        let m = app, wt = m.worktree(s.worktreeId)
        let c = UNMutableNotificationContent()
        c.title = app.catalog.displayName(s) + (s.status == .waiting ? String(localized: " needs you")
            : s.status == .error ? String(localized: " ran into an error") : String(localized: " finished"))
        c.subtitle = [wt?.displayName, m.projectName(wt?.repoId)].compactMap { $0 }.joined(separator: " · ")   // as its Needs You row
        c.body = s.summary.isEmpty ? (s.status == .waiting ? String(localized: "Waiting for your answer") : String(localized: "Ready for review")) : s.summary
        c.sound = sound(s.status); c.userInfo = ["session": s.id]
        if let cat = Self.category(s) { c.categoryIdentifier = cat }
        if !allowed, NSApp.isActive {   // banners are off: say it inside Kelp instead
            Banner.show(c.body, action: (String(localized: "Show"), { app.workbench.focus(session: s.id) }),
                        title: c.title, subtitle: c.subtitle, icon: app.catalog.icon(s.agent, size: 24))
        }
        let rid = "\(s.id)-\(s.status.rawValue)"
        center?.add(UNNotificationRequest(identifier: rid, content: c, trigger: nil))
        posted[s.id] = rid
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// What the banner can answer: a permission (Allow / Deny), or a reply typed to an agent back at its prompt. A question
    /// with a menu of its own (AskUserQuestion) has neither: typed text would wait behind the menu.
    static func category(_ s: Session) -> String? {
        asksPermission(s) ? "permission" : [.done, .error].contains(s.status) ? "reply" : nil
    }

    /// "Claude needs your permission to use Bash", a blocked OSC report of kind permission…
    static func asksPermission(_ s: Session) -> Bool {
        let t = s.summary.lowercased()
        return s.status == .waiting && ["permission", "approve", "allow"].contains { t.contains($0) }
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        if let uri = r.notification.request.content.userInfo["uri"] as? String {
            await MainActor.run { NSApp.activate(); app.workbench.open(uri) }
            return
        }
        guard let id = r.notification.request.content.userInfo["session"] as? String else { return }
        let action = r.actionIdentifier, reply = (r as? UNTextInputNotificationResponse)?.userText
        let all = r.notification.request.content.userInfo["sessions"] as? [String] ?? [id]
        await MainActor.run {
            if action == "continue" { Self.goOn(app, all); return }
            if action == "reply", let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Sent without Kelp coming forward; refused (a half-typed line in its prompt), the agent is shown with the banner.
                Task { if await app.call(SessionSend(id: id, text: reply, enter: true)) == nil { NSApp.activate(); app.workbench.focus(session: id) } }
                return
            }
            guard action == "allow" || action == "deny" else {
                NSApp.activate()
                app.workbench.focus(session: id)
                return
            }
            Task {
                // Answered without Kelp coming forward; if the menu is gone (answered in the terminal), show the agent.
                let ok = await app.call(SessionChoose(id: id, answer: action)) ?? false
                if !ok { NSApp.activate(); app.workbench.focus(session: id) }
            }
        }
    }
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
