// How the buttons on a banner (Allow, Deny, a reply or Continue) answer an agent without bringing Kelp forward.
import Agents
import AppKit
import Core
@preconcurrency import UserNotifications   // the notification center and its settings aren't marked Sendable

extension Notifier {
    /// Returns the banner's category, which says what it can answer: a permission (Allow / Deny), or a reply typed to
    /// an agent back at its prompt (or its Continue, `QuickReply.goOn`). A question with a menu of its own
    /// (AskUserQuestion) gets neither, because typed text would wait behind the menu.
    static func category(_ session: Session) -> String? {
        session.asksPermission ? "permission" : QuickReply.fits(session) ? "reply" : nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse)
        async
    {
        if let uri = r.notification.request.content.userInfo["uri"] as? String {
            await MainActor.run {
                NSApp.activate()
                app.workbench.open(uri)
            }
            return
        }
        guard let id = r.notification.request.content.userInfo["session"] as? String else { return }
        let action = r.actionIdentifier
        let reply = action == "goOn" ? QuickReply.goOn.text : (r as? UNTextInputNotificationResponse)?.userText
        let all = r.notification.request.content.userInfo["sessions"] as? [String] ?? [id]
        let question = r.notification.request.content.userInfo["question"] as? String
        await MainActor.run {
            if action == "continue" {
                Notifications.goOn(app, all)
                return
            }
            if action == "reply" || action == "goOn", let reply,
                !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Send the reply without bringing Kelp forward. If the send is refused (a half-typed line in the
                // prompt), show the agent along with the error banner.
                Task {
                    if await app.call(SessionSend(id: id, text: reply, enter: true)) == nil {
                        NSApp.activate()
                        app.workbench.focus(session: id)
                    }
                }
                return
            }
            guard action == "allow" || action == "deny" else {
                NSApp.activate()
                app.workbench.focus(session: id)
                return
            }
            answer(id, action, question: question)
        }
    }

    /// Answers a permission request without bringing Kelp forward. If the agent's menu is gone (answered in the
    /// terminal, or another menu is up), it shows the agent instead.
    func answer(_ id: String, _ action: String, question: String?, run: String? = nil) {
        Task {
            let ok = await app.call(SessionChoose(id: id, answer: action, question: question, run: run)) ?? false
            if !ok {
                NSApp.activate()
                app.workbench.focus(session: id)
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        [.banner, .sound]
    }
}
