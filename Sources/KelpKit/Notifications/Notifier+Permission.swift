// Whether macOS lets Kelp post notifications (Kelp says so once when it doesn't), and the test notification in
// Settings.
import AppKit
import Core
@preconcurrency import UserNotifications   // the notification center and its settings aren't marked Sendable

extension Notifier {
    /// Checks whether macOS switched Kelp's banners off (System Settings › Notifications), and says so once instead of
    /// failing silently.
    /// Called at launch and when Kelp comes to the front.
    func checkAllowed() {
        center?.getNotificationSettings { settings in
            let off = settings.authorizationStatus == .denied || settings.alertSetting == .disabled
            Task { @MainActor in
                self.allowed = !off
                let defaults = UserDefaults.standard
                guard off else {
                    defaults.removeObject(forKey: "notifications.warnedOff")
                    return
                }
                guard !defaults.bool(forKey: "notifications.warnedOff") else { return }
                defaults.set(true, forKey: "notifications.warnedOff")
                Banner.show(
                    String(
                        localized:
                            "Notifications for Kelp are turned off in System Settings, so you won't hear when an agent needs you."
                    ), style: .error,
                    action: (
                        String(localized: "Open Settings"),
                        {
                            let id = Bundle.main.bundleIdentifier ?? ""
                            if let url = URL(
                                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
                            {
                                PreviewLinks.openOutside(url)
                            }
                        }
                    ))
            }
        }
    }

    /// Sends the banner for "Send Test Notification" in Settings › Notifications, or calls back `false` when macOS has
    /// notifications turned off for Kelp.
    func sendTest(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else {
            done(false)
            return
        }
        Task {
            let settings = await center.notificationSettings()
            let off = settings.authorizationStatus == .denied || settings.alertSetting == .disabled
            if !off {
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Kelp can reach you")
                content.body = String(localized: "This is how you'll hear that an agent finished or needs you.")
                content.sound = .default
                do {
                    try await center.add(UNNotificationRequest(identifier: "kelp-test", content: content, trigger: nil))
                } catch {
                    Banner.show(
                        String(localized: "macOS didn't take the notification: \(error.localizedDescription)"),
                        style: .error)
                }
            }
            done(!off)
        }
    }
}
