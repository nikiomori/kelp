// What built-ins post through the shell's notifications, and whether a session asks a permission.
import Agents
import AppKit
import Core
@preconcurrency import UserNotifications   // its center and settings aren't marked Sendable

/// What the built-ins ask of the shell's notifications (`Notifier`, the running app's).
@MainActor
package enum Notifications {
    /// A built-in's notification, under the shell's rules: held while you type, and a banner in Kelp (with `action` as
    /// its button) when macOS has them turned off. `id` is its own: one added again under the same id may show silently.
    package static func notifyUser(
        _ app: AppModel, _ id: String, _ content: UNNotificationContent,
        action: (title: String, run: @MainActor () -> Void)? = nil
    ) {
        app.notifier?.postAlert(id, content, action: action)
    }

    /// The Continue of a "limitReset" notification: "continue" to each of `ids` that still stands where the limit left
    /// it (one the user went on with meanwhile isn't told twice).
    package static func goOn(_ app: AppModel, _ ids: [String]) {
        let still = ids.filter { id in app.session(id).map { [.done, .error].contains($0.status) } ?? false }
        Task { for id in still { _ = await app.call(SessionSend(id: id, text: "continue", enter: true)) } }
    }

    /// A permission answered from outside Kelp's window (the agent strip's card), as from its banner.
    package static func answer(_ app: AppModel, _ id: String, _ action: String, question: String?) {
        app.notifier?.answer(id, action, question: question)
    }
}
