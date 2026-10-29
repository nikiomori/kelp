import Foundation
import ServiceManagement

/// Kelp's background item (System Settings › General › Login Items & Extensions). When an app quits, macOS ends what it
/// started unless Background Task Management lets it run in the background (loginwindow: "not allowed by BTM so terminating
/// its subordinates"): kelpd and every agent, on a quit or an update. The item gives Kelp a switch there and tells it
/// whether it's on.
enum BackgroundItem {
    // Resources/dev.kelp.kelpd.plist, in Contents/Library/LaunchAgents; Kelp Dev's is a copy under its own label.
    #if DEBUG
    static let label = "dev.kelp.kelpd.dev"
    #else
    static let label = "dev.kelp.kelpd"
    #endif
    private static var service: SMAppService { .agent(plistName: label + ".plist") }
    private static var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Once: turned off in System Settings, it stays off, and the app says once per launch what that costs.
    @MainActor static func register() {
        guard bundled else { return }
        if [.notRegistered, .notFound].contains(service.status) {
            do { try service.register() } catch { NSLog("Kelp: the background service couldn't be added to Login Items: \(error)") }
        }
        guard service.status == .requiresApproval, !told else { return }
        told = true
        Banner.show(String(localized: "Kelp isn't allowed to run in the background: quitting or updating it ends running agents."),
                    action: (String(localized: "Open Login Items"), { SMAppService.openSystemSettingsLoginItems() }))
    }
    @MainActor private static var told = false
}
