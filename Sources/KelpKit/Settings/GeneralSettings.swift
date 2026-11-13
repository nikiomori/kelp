import DesignKit
import SwiftUI

/// Settings › General under Language: how Kelp updates itself, and whether its agents outlive a quit (the background
/// service, which macOS allows in Login Items). What the Kelp menu and a banner said, kept where settings are.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var checks = false
    @State private var downloads = false
    @State private var blocked: Bool?

    /// "Kelp 0.9.0 (10)"; a build run from .build has no version, only its name.
    private static let name: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "Kelp" }
        return (info["CFBundleVersion"] as? String).map { "Kelp \(version) (\($0))" } ?? "Kelp \(version)"
    }()

    var body: some View {
        Section("Updates") {
            if let controller = app.updates.controller {
                Toggle(
                    isOn: Binding(
                        get: { checks },
                        set: {
                            checks = $0
                            controller.updater.automaticallyChecksForUpdates = $0
                        })
                ) { Self.row("arrow.down.circle.fill", 0x007AFF, Text("Check for updates automatically")) }
                Toggle(
                    isOn: Binding(
                        get: { downloads },
                        set: {
                            downloads = $0
                            controller.updater.automaticallyDownloadsUpdates = $0
                        })
                ) {
                    Self.row(
                        "tray.and.arrow.down.fill", 0x34C759, Text("Download them in the background"),
                        help: String(localized: "A pill over the sidebar says when one is ready; a quit installs it."))
                }
                .disabled(!checks)
                LabeledContent {
                    Button("Check Now") { controller.checkForUpdates(nil) }
                } label: {
                    Self.row("shippingbox.fill", 0x8E8E93, Text(verbatim: Self.name))
                }
            } else {
                LabeledContent {
                    Text("This build doesn't update itself.").foregroundStyle(.secondary)
                } label: {
                    Self.row("shippingbox.fill", 0x8E8E93, Text(verbatim: Self.name))
                }
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
                    Self.row(
                        "moon.fill", 0x5856D6, Text("Agents keep running when Kelp quits"),
                        help: String(localized: "Kelp's background service runs them; macOS allows it in Login Items."))
                    // Only when it's off: the one state that needs doing something about stays in view.
                    if blocked == true {
                        Text("Off in Login Items: quitting or updating Kelp ends them.").foregroundStyle(
                            Color.textOrange)
                    }
                }
                .task { blocked = await BackgroundItem.blocked }
            }
            LabeledContent {
                Button("Restart…") { app.extensions.run("workbench.restartService") }
            } label: {
                Self.row(
                    "arrow.clockwise", 0x8E8E93, Text("Background service"),
                    help: String(localized: "Runs the agents and terminals. Restarting keeps them when it can."))
            }
        }
    }

    /// A row's title as the generated rows show it (`SettingRow`): its tile, and what it doesn't say behind a ⓘ.
    private static func row(_ symbol: String, _ tint: Int, _ title: Text, help: String? = nil) -> some View {
        HStack(spacing: Metrics.gap) {
            SettingsIcon(symbol: symbol, tint: NSColor(hex: tint))
            title
            if let help { HelpMark(text: help) }
        }
    }
}
