// How built-ins post notifications through the shell, and answer an agent's permission request from outside the window.
import Agents
import AppKit
import Core
@preconcurrency import UserNotifications   // the notification center and its settings aren't marked Sendable

/// The notification calls that built-ins can make on the shell (`Notifier` does the work in the running app).
@MainActor
package enum Notifications {
    /// Shows a built-in's notification under the shell's rules: it is held while you type, and becomes a banner in Kelp
    /// (with `action` as its button) when macOS notifications are turned off. `id` identifies it, so a notification
    /// added again under the same id may show silently. `goingOn` lists the sessions the notification is about; its
    /// Continue button (on the macOS banner or on Kelp's own banner) tells each of them to go on.
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

    /// Handles Continue on a `goingOn` notification. It sends "continue" to each session in `ids` that is still done
    /// or failed, so a session the user already went on with isn't told twice.
    static func goOn(_ app: AppModel, _ ids: [String]) {
        let still = ids.filter { id in app.session(id).map { [.done, .error].contains($0.status) } ?? false }
        Task { for id in still { _ = await app.call(SessionSend(id: id, text: "continue", enter: true)) } }
    }

    /// Answers a permission request from outside Kelp's window (the card on the agent strip), as its banner does.
    package static func answer(_ app: AppModel, _ id: String, _ action: String, question: String?) {
        app.notifier?.answer(id, action, question: question)
    }
}
