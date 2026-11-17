import KelpKit
import SwiftUI

/// The Send Test Notification button in Settings › Notifications. It sends a banner now, so a setting that silences
/// Kelp shows up before an agent waits on you.
struct TestNotificationRow: View {
    let app: AppModel

    var body: some View {
        Section {
            Button("Send Test Notification") { app.extensions.run("notifications.test") }
        }
    }
}
