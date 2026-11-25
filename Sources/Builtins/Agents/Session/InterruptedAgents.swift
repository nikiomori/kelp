import AppKit
import Core
import DesignKit
import KelpKit
@preconcurrency import UserNotifications   // the notification content isn't marked Sendable

/// Offers to continue the agents whose turn Kelp's going down cut short (`Session.interrupted`): a banner that stays
/// until it is answered or closed, and one notification for all of them while Kelp isn't in front. With "Continue
/// working agents after a crash" on, the daemon has them go on by itself, so nothing is offered. The app has one of
/// these, made as a part when Kelp starts.
@MainActor
final class InterruptedAgents {
    static func start(_ app: AppModel) { _ = app.part { InterruptedAgents(app: app) } }

    private let app: AppModel
    /// The agents already offered: shown again after a reconnect, the same banner would be old news.
    private var told = Set<String>()

    private init(app: AppModel) {
        self.app = app
        // Asked again once a workspace is on screen, because at launch the sessions can come before the window.
        track(owner: self) {
            app.connected && app.workbench.workspaceId != nil ? app.sessions.filter(\.interrupted).map(\.id) : []
        } changed: { [weak self] in
            self?.offer($0)
        }
    }

    /// The agents to offer: all of `cut` when any of them is news, none when they go on by themselves.
    static func toOffer(_ cut: [String], told: Set<String>, goOnByThemselves: Bool) -> [String] {
        goOnByThemselves || cut.allSatisfy(told.contains) ? [] : cut
    }

    private func offer(_ ids: [String]) {
        let cut = Self.toOffer(ids, told: told, goOnByThemselves: app.settings[SettingKeys.resumeAfterCrash])
            .compactMap(app.session)
        told.formUnion(ids)
        guard !cut.isEmpty else { return }
        let at = (cut.compactMap(\.interruptedAt).max() ?? Date()).formatted(date: .omitted, time: .shortened)
        let app = app
        Banner.show(
            String(localized: "They’re paused since \(at). Agents you paused yourself aren’t affected."),
            action: (String(localized: "Continue All"), { Self.continueAll(app) }),
            title: String(localized: "Kelp closed while \(cut.count) agents were working"), stays: true)
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(cut.count) agents stopped: Kelp closed at \(at)")
        content.body = String(localized: "Click to open Kelp with Continue All.")
        Notifications.notifyUser(app, "interrupted", content)
    }

    /// Has every agent still cut short go on, in the sidebar's order, one at a time a second apart so a dozen don't
    /// start at once. Each is sent the line that has it go on, which wakes it.
    static func continueAll(_ app: AppModel) {
        let ids = app.inSidebarOrder(app.sessions.filter(\.interrupted)).map(\.id)
        _ = Task {
            for (index, id) in ids.enumerated() {
                if index > 0 { try await Task.sleep(for: .seconds(1)) }
                guard app.session(id)?.interrupted == true else { continue }   // gone on meanwhile
                _ = await app.call(SessionSend(id: id, text: Session.goOnText, enter: true))
            }
        }
    }
}
