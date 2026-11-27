// Who has an agent's page. It is the agent, or the user who took the page with a click, a key or Take Over, or the
// user because the agent asked them to do something there (`kelp browser ask`).
import AppKit
import Core
import DesignKit
import KelpKit

extension BrowserTab {
    /// How long the user may leave a page they took before the strip asks whether to hand it back.
    static let remindAfter: TimeInterval = 120

    /// Watches the user's own clicks and keys in the page while an agent drives it. The first click or key takes the
    /// page, but scrolling and pointing don't. A key with ⌘ is a shortcut (copy, find), not typing into the page.
    func watchUser() {
        guard userWatch == nil else { return }
        userWatch = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
            [weak self] event in
            self?.userActed(event)
            return event
        }
    }

    func stopWatchingUser() {
        if let userWatch { NSEvent.removeMonitor(userWatch) }
        userWatch = nil
    }

    private func userActed(_ event: NSEvent) {
        guard let drive, let window = web.window, event.window === window else { return }
        let inPage =
            event.type == .keyDown
            ? !event.modifierFlags.contains(.command)
                && (window.firstResponder as? NSView)?.isDescendant(of: web) == true
            : web.bounds.contains(web.convert(event.locationInWindow, from: nil))
        guard inPage else { return }
        drive.userAt = Date()
        if !drive.takenOver {
            drive.takenOver = true
            showAgentBar()
        }
        // Show the reminder once the user has left the page alone for `remindAfter`.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.remindAfter + 1) { [weak self] in
            MainActor.assumeIsolated { self?.showAgentBar() }   // asyncAfter runs on the main queue
        }
    }

    /// Handles `kelp browser ask`. With `text`, the page goes to the user and the strip on the page asks them. With
    /// `ended`, the question is over, and the page goes back to the agent when the user said Done (`allow`). The answer
    /// says where the page is now.
    func ask(_ args: JSONValue) async throws -> JSONValue {
        guard let drive else { throw RPCError.invalidParams("That tab shows no page of an agent’s.") }
        if let text = args["text"]?.string {
            drive.asked = (text, args["askingSession"]?.string ?? args["session"]?.string ?? "")
            drive.takenOver = true
            drive.userAt = Date()
            showAgentBar()
            return .object(["asked": .string(text)])
        }
        let done = args["ended"]?.string == "allow"
        drive.asked = nil
        drive.takenOver = !done
        showAgentBar()
        return try await settled()
    }

    /// Handles Done on the strip. It answers the agent's question (as Allow on the agent's row would) and gives the
    /// page back to the agent.
    func done() {
        guard let asked = drive?.asked else { return }
        drive?.takenOver = false
        showAgentBar()
        let question = UIBrowserAsk.rowQuestion(asked.text)
        Task { await app.call(SessionChoose(id: asked.session, answer: "allow", question: question)) }
    }

    /// Names who drives the page, for the user. A subagent (`who`) is named by the task it was given, otherwise the
    /// name is the agent's.
    func driverName(_ who: String) -> String {
        let session = drive?.driver.flatMap { app.session($0) }
        guard !who.isEmpty else { return session.map { app.catalog.name($0.agent) } ?? String(localized: "The agent") }
        let run = session?.runningSubagents.first { $0.id == who }
        return run.flatMap { $0.task ?? ($0.kind.isEmpty ? nil : $0.kind) } ?? String(localized: "A subagent")
    }

    /// What the strip says and offers now: who has the page, and the one thing to do about it.
    func stripLook() -> (text: String, button: String, tip: String) {
        guard let drive else { return ("", "", "") }
        let who = driverName(drive.subagent ?? "")
        if let asked = drive.asked {
            return (
                String(localized: "\(who) asks: \(asked.text)"), String(localized: "Done"),
                String(localized: "Give the page back to \(who): it goes on from here")
            )
        }
        if drive.takenOver {
            let idle = Date().timeIntervalSince(drive.userAt) >= Self.remindAfter
            return (
                idle
                    ? String(localized: "You have this page · hand it back to \(who)?")
                    : String(localized: "You have this page · \(who) waits"),
                String(localized: "Hand Back"), String(localized: "Let \(who) click and type here again")
            )
        }
        if let site = loginSite {
            guard allowsLogin(site) else {
                return (
                    String(localized: "Agents no longer use your login on \(site)"),
                    loginStopped != nil ? String(localized: "Undo") : String(localized: "Take Over"),
                    String(localized: "Let agents use your login on \(site) again")
                )
            }
            return (
                String(localized: "\(who) uses your login on \(site)"), String(localized: "Stop"),
                String(localized: "Agents stop using your login on \(site); the page stays yours")
            )
        }
        return (
            String(localized: "\(who) is using this page"), String(localized: "Take Over"),
            String(localized: "Your first click or key in the page takes it too; scrolling doesn’t")
        )
    }
}

extension BrowserTab {
    /// Whether agents may still use the user's login on `site` (Settings › Browser).
    func allowsLogin(_ site: String) -> Bool {
        AgentSites.allowed(site, in: AgentSites.entries(app.settings[SettingKeys.agentSites])) != nil
    }

    /// The strip's button: Done on an agent's question, Stop or Undo on a page with the user's login, else Take Over
    /// or Hand Back.
    func toggleTakeOver() {
        if drive?.asked != nil { return done() }
        if stopOrUndoLogin() { return }
        drive?.takenOver.toggle()
        showAgentBar()
    }

    /// Stop and Undo on the strip of a page with the user's login: Stop takes the site out of the list, so the agent's
    /// next command there is refused, and Undo puts it back. Returns whether the click was one of them.
    /// Each is one change on the daemon's list, so a site kelpd allows meanwhile stays.
    func stopOrUndoLogin() -> Bool {
        guard let site = loginSite, drive?.takenOver != true else { return false }
        let change: SettingsAgentSite
        if allowsLogin(site) {
            loginStopped = app.settings[SettingKeys.agentSites].first { $0["site"]?.string == site }
            change = SettingsAgentSite(site: site)
        } else if let stopped = loginStopped {
            change = SettingsAgentSite(site: site, entry: stopped)
            loginStopped = nil
        } else {
            return false
        }
        Task { [weak self] in
            await self?.app.call(change)
            self?.showAgentBar()
        }
        return true
    }

    /// The chip before the address on a page with the user's login. It takes the host chip's place: a page driven from
    /// a host never has the login.
    func showLoginChip() {
        guard let site = loginSite, !requiresHostNetwork else { return }
        if !followsLogins {   // the strip says whether the site is still allowed: Stop, Settings › Browser, kelpd
            followsLogins = true
            track(owner: self, now: false) { [app] in
                app.settings[SettingKeys.agentSites]
            } changed: { [weak self] _ in
                self?.showAgentBar()
            }
        }
        hostChip.title = String(localized: "Your login")
        hostChip.toolTip = String(localized: "Agents use your login from Kelp’s browser on \(site): Settings › Browser")
        hostChip.onClick = { [weak self] in self?.app.workbench.open("settings:browser") }
        hostChip.isHidden = false
    }
}
