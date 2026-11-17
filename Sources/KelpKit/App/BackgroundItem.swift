import Foundation
import ServiceManagement

/// Kelp's background item (System Settings › General › Login Items & Extensions). When an app quits, macOS ends what
/// it started, which for Kelp is kelpd and every agent, on a quit or an update. That happens unless Background Task
/// Management lets the app run in the background (loginwindow logs "not allowed by BTM so terminating its
/// subordinates"). The item gives Kelp a switch there and tells Kelp whether it's on.
enum BackgroundItem {
    /// The label of Resources/dev.kelp.kelpd.plist, which sits in Contents/Library/LaunchAgents. Kelp Beta and Kelp Dev
    /// get copies under labels that follow their bundle ids (dev.kelp.app.beta → dev.kelp.kelpd.beta), as
    /// scripts/bundle.sh names them.
    static let label = "dev.kelp.kelpd" + (Bundle.main.bundleIdentifier ?? "").dropFirst("dev.kelp.app".count)
    private static var service: SMAppService { .agent(plistName: label + ".plist") }
    static var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Registers the item once. If the user turned it off in System Settings, it stays off, and the app says once per
    /// launch what that costs. This runs off the main thread, because each `status` waits for the system while the
    /// window is still empty at launch.
    @MainActor static func register() {
        guard bundled else { return }
        Task {
            let waiting = await Task.detached(priority: .utility) { () -> Bool in
                let item = service
                if [.notRegistered, .notFound].contains(item.status) {
                    do { try item.register() } catch {
                        NSLog("Kelp: the background service couldn't be added to Login Items: \(error)")
                    }
                }
                return item.status == .requiresApproval
            }.value
            guard waiting, !told else { return }
            told = true
            Banner.show(
                String(
                    localized:
                        "Kelp isn't allowed to run in the background: quitting or updating it ends running agents."),
                action: (String(localized: "Open Login Items"), { SMAppService.openSystemSettingsLoginItems() }))
        }
    }
    @MainActor private static var told = false

    /// Whether macOS would end what Kelp started when Kelp quits.
    static var blocked: Bool {
        get async {
            bundled ? await Task.detached(priority: .utility) { service.status == .requiresApproval }.value : false
        }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
