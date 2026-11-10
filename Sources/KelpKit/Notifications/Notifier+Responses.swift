// A notification's answers: Allow, Deny, a reply or Continue from the banner, without Kelp coming forward.
import Agents
import AppKit
import Core
@preconcurrency import UserNotifications   // its center and settings aren't marked Sendable

extension Notifier {
    /// What the banner can answer: a permission (Allow / Deny), or a reply typed to an agent back at its prompt (or its
    /// Continue, `QuickReply.goOn`). A question
    /// with a menu of its own (AskUserQuestion) has neither: typed text would wait behind the menu.
    static func category(_ s: Session) -> String? {
        s.asksPermission ? "permission" : QuickReply.fits(s) ? "reply" : nil
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
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
                // Sent without Kelp coming forward; refused (a half-typed line in its prompt), the agent is shown with the banner.
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

    /// Answered without Kelp coming forward; if that menu is gone (answered in the terminal, another one up), show the agent.
    func answer(_ id: String, _ action: String, question: String?) {
        Task {
            let ok = await app.call(SessionChoose(id: id, answer: action, question: question)) ?? false
            if !ok {
                NSApp.activate()
                app.workbench.focus(session: id)
            }
        }
    }
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        [.banner, .sound]
    }
}
