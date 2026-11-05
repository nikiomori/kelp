import SwiftUI
import DesignKit

/// Settings › General under Language: how Kelp updates itself, and whether its agents outlive a quit (the background
/// service, which macOS allows in Login Items). What the Kelp menu and a banner said, kept where settings are.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var checks = false
    @State private var downloads = false
    @State private var blocked: Bool?

    /// "Kelp 0.9.0 (10)"; a build run from .build has no version, only its name.
    private static let name: String = {
        let i = Bundle.main.infoDictionary ?? [:]
        guard let v = i["CFBundleShortVersionString"] as? String else { return "Kelp" }
        return (i["CFBundleVersion"] as? String).map { "Kelp \(v) (\($0))" } ?? "Kelp \(v)"
    }()

    var body: some View {
        Section("Updates") {
            if let c = app.updates.controller {
                Toggle("Check for updates automatically", isOn: Binding(get: { checks }, set: {
                    checks = $0
                    c.updater.automaticallyChecksForUpdates = $0
                }))
                Toggle(isOn: Binding(get: { downloads }, set: {
                    downloads = $0
                    c.updater.automaticallyDownloadsUpdates = $0
                })) {
                    Text("Download them in the background")
                    Text("A pill over the sidebar says when one is ready; a quit installs it.")
                }
                .disabled(!checks)
                LabeledContent(Self.name) { Button("Check Now") { c.checkForUpdates(nil) } }
            } else {
                LabeledContent(Self.name) { Text("This build doesn't update itself.").foregroundStyle(.secondary) }
            }
        }
        .onAppear {
            checks = app.updates.controller?.updater.automaticallyChecksForUpdates ?? false
            downloads = app.updates.controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        Section("Background") {
            if BackgroundItem.bundled {
                LabeledContent {
                    Button("Open Login Items") { BackgroundItem.openSettings() }
                } label: {
                    Text("Agents keep running when Kelp quits")
                    switch blocked {
                    case true?: Text("Off in Login Items: quitting or updating Kelp ends them.").foregroundStyle(Color.textOrange)
                    case false?: Text("On: Kelp's background service is allowed in Login Items.")
                    case nil: Text("Checking…")
                    }
                }
                .task { blocked = await BackgroundItem.blocked }
            }
            LabeledContent {
                Button("Restart…") { app.extensions.run("workbench.restartService") }
            } label: {
                Text("Background service")
                Text("Runs the agents and terminals. Restarting keeps them when it can.")
            }
        }
    }
}
