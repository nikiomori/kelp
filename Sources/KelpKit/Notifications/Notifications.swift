// What built-ins post through the shell's notifications, and whether a session asks a permission.
import Agents
import AppKit
import Core
@preconcurrency import UserNotifications   // its center and settings aren't marked Sendable

/// What the built-ins can ask of the shell's notifications (`Notifier` in the running app).
@MainActor
package enum Notifications {
    /// Shows a built-in's notification under the shell's rules: it is held while you type, and becomes a banner in Kelp
    /// (with `action` as its button) when macOS notifications are turned off. `id` identifies it, so a notification
    /// added again under the same id may show silently. `goingOn` lists the sessions it is about; its Continue (on the
    /// banner, or Kelp's own) tells each of them to go on.
    package static func notifyUser(
        _ app: AppModel, _ id: String, _ content: UNNotificationContent,
        action: (title: String, run: @MainActor () -> Void)? = nil, goingOn ids: [String] = []
    ) {
        guard let first = ids.first, let told = content.mutableCopy() as? UNMutableNotificationContent else {
            return app.notifier?.postAlert(id, content, action: action) ?? ()
        }
        told.categoryIdentifier = Notifier.goOnCategory
        told.userInfo["session"] = first
        told.userInfo["sessions"] = ids
        app.notifier?.postAlert(id, told, action: action ?? (String(localized: "Continue"), { goOn(app, ids) }))
    }

    /// The Continue of a `goingOn` notification: "continue" to each of `ids` that still stands where it stopped (one
    /// the user went on with meanwhile isn't told twice).
    static func goOn(_ app: AppModel, _ ids: [String]) {
        let still = ids.filter { id in app.session(id).map { [.done, .error].contains($0.status) } ?? false }
        Task { for id in still { _ = await app.call(SessionSend(id: id, text: "continue", enter: true)) } }
    }

    /// A permission answered from outside Kelp's window (the agent strip's card), as from its banner.
    package static func answer(_ app: AppModel, _ id: String, _ action: String, question: String?) {
        app.notifier?.answer(id, action, question: question)
    }
}
