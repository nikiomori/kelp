import Foundation
import ServiceManagement

/// Kelp's background item (System Settings › General › Login Items & Extensions). When an app quits, macOS ends what it
/// started unless Background Task Management lets it run in the background (loginwindow: "not allowed by BTM so terminating
/// its subordinates"): kelpd and every agent, on a quit or an update. The item gives Kelp a switch there and tells it
/// whether it's on.
enum BackgroundItem {
    /// Resources/dev.kelp.kelpd.plist, in Contents/Library/LaunchAgents; Kelp Beta's and Kelp Dev's are copies under
    /// labels that follow their ids (dev.kelp.app.beta → dev.kelp.kelpd.beta), as scripts/bundle.sh names them.
    static let label = "dev.kelp.kelpd" + (Bundle.main.bundleIdentifier ?? "").dropFirst("dev.kelp.app".count)
    private static var service: SMAppService { .agent(plistName: label + ".plist") }
    private static var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Once: turned off in System Settings, it stays off, and the app says once per launch what that costs.
    /// Off the main thread: each `status` waits for the system, with the window still empty at launch.
    @MainActor static func register() {
        guard bundled else { return }
        Task {
            let waiting = await Task.detached(priority: .utility) { () -> Bool in
                let s = service
                if [.notRegistered, .notFound].contains(s.status) {
                    do { try s.register() } catch { NSLog("Kelp: the background service couldn't be added to Login Items: \(error)") }
                }
                return s.status == .requiresApproval
            }.value
            guard waiting, !told else { return }
            told = true
            Banner.show(String(localized: "Kelp isn't allowed to run in the background: quitting or updating it ends running agents."),
                        action: (String(localized: "Open Login Items"), { SMAppService.openSystemSettingsLoginItems() }))
        }
    }
    @MainActor private static var told = false
}
