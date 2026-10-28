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
        ], intentIdentifiers: [])])
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in Task { @MainActor in self.checkAllowed() } }
        track(owner: self) { [app] in app.sessions } changed: { [weak self] _ in self?.updateBadge() }
        track(owner: self) { [app] in app.limits } changed: { [weak self] u in self?.limitsChanged(u) }
    }

    private var limitAlerts = LimitAlerts()
    private var forecastTold = Set<String>()   // limits already warned about, until they stop filling faster than they reset
    private func limitsChanged(_ u: UsageGet.Result?) {
        guard let u else { return }
        for a in limitAlerts.update(u, first: Int(app.settings.string("usage.alertAt") ?? "80")) {
            let name = app.catalog.all.first { $0.id == a.agent }?.name ?? a.agent
            let c = UNMutableNotificationContent()
            c.title = name + String(localized: " is at ") + "\(Int(a.percent.rounded())) %"
            c.body = a.kind + (a.resets.map { " · " + String(localized: "resets ") + $0 } ?? "")
            c.sound = a.level >= 95 ? .default : nil
            center?.add(UNNotificationRequest(identifier: "limit-\(a.agent)-\(a.kind)-\(a.level)", content: c, trigger: nil))
            if !allowed, NSApp.isActive { Banner.show("\(c.title) · \(c.body)") }
        }
        forecastChanged(u)
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
            c.title = name + String(localized: ": \(l.kind) limit full in \(LimitForecast.duration(eta))")
            c.body = String(localized: "At this pace it fills before it resets.")
            center?.add(UNNotificationRequest(identifier: "forecast-\(key)", content: c, trigger: nil))
            if !allowed, NSApp.isActive { Banner.show("\(c.title) · \(c.body)") }
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
        // What the agent itself said with this change (a permission request, an error) beats its last reply.
        if s.status != .done, !s.summary.isEmpty, s.summary != old?.summary { post(s); return }
        Task { await summarizeThenNotify(s) }
    }

    /// One-line summary for the banner and sidebar from the agent's own last reply, then the notification.
    private func summarizeThenNotify(_ s: Session) async {
        var s = s
        // Claude Code: its own last reply (the terminal around it — spinners, mode lines — reads as nonsense when summarized).
        // The Stop hook can come a moment before the transcript has the final message.
        try? await Task.sleep(for: .milliseconds(1200))
        if let reply = await app.quiet(SessionLastReply(id: s.id)) ?? nil {
            let line = Self.firstSentence(reply)
            s.summary = line
            _ = await app.quiet(SessionAnnotate(id: s.id, summary: line))
        }
        post(s)   // other agents: no summary; the state says enough
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

    private func post(_ s: Session) {
        let app = self.app
        // No banner if the user is already looking at that pane (what it asks stays marked until it's answered).
        if NSApp.isActive, app.workbench.isViewing(session: s.id) { return }
        let m = app, wt = m.worktree(s.worktreeId)
        let c = UNMutableNotificationContent()
        c.title = app.catalog.displayName(s) + (s.status == .waiting ? String(localized: " needs you")
            : s.status == .error ? String(localized: " ran into an error") : String(localized: " finished"))
        c.subtitle = [wt?.displayName, m.projectName(wt?.repoId)].compactMap { $0 }.joined(separator: " · ")   // as its Needs You row
        c.body = s.summary.isEmpty ? (s.status == .waiting ? String(localized: "Waiting for your answer") : String(localized: "Ready for review")) : s.summary
        c.sound = .default; c.userInfo = ["session": s.id]
        if let cat = Self.category(s) { c.categoryIdentifier = cat }
        if !allowed, NSApp.isActive {   // banners are off: say it inside Kelp instead
            Banner.show("\(c.title)\(s.summary.isEmpty ? "" : ": " + s.summary)", action: (String(localized: "Show"), { app.workbench.focus(session: s.id) }))
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
        guard let id = r.notification.request.content.userInfo["session"] as? String else { return }
        let action = r.actionIdentifier, reply = (r as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
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
