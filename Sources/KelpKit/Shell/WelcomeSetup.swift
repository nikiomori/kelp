import Core
import DesignKit
import SwiftUI

/// The first-run welcome's three choices: the theme, the text size and the agent a new chat starts. Each applies as
/// it's picked and uses the same tiles as Settings, where it can be changed later. The welcome's buttons lead on.
struct WelcomeSetup: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let agents = Self.firstAgents(
            app.catalog.installed.map(\.id), current: app.settings[SettingKeys.defaultAgent])
        VStack(alignment: .leading, spacing: Metrics.sheetInset) {
            choice("Theme") { ThemeGallery(selection: binding(SettingKeys.theme), kelpOnly: true) }
            choice("Text size") {
                PictureGrid(
                    key: SettingKeys.textSize.key, options: ["normal", "large", "larger"],
                    selection: binding(SettingKeys.textSize),
                    label: { SettingRow.label(SettingKeys.textSize.key, $0, app) })
            }
            if !agents.isEmpty {
                choice("Default agent") {
                    PictureGrid(
                        key: SettingKeys.defaultAgent.key, options: agents,
                        selection: binding(SettingKeys.defaultAgent),
                        label: { app.catalog.name($0) },
                        art: { id in
                            AnyView(
                                Group {
                                    if let img = app.catalog.icon(id, size: 30) {
                                        Image(nsImage: img).resizable().frame(width: 30, height: 30)
                                    }
                                })
                        })
                }
            }
        }
        .frame(width: 560)   // the five theme cards in one row
    }

    /// The agents to offer: one row at most, with the chosen one first, instead of a wall of every agent installed
    /// (Settings has them all).
    static func firstAgents(_ installed: [String], current: String?) -> [String] {
        let known = [Session.claudeAgent, Session.codexAgent, "gemini", "cursor", "copilot", "opencode"]
        var picked = known.filter(installed.contains) + installed.filter { !known.contains($0) }
        if let current, installed.contains(current) {
            picked.removeAll { $0 == current }
            picked.insert(current, at: 0)
        }
        return Array(picked.prefix(PictureGrid.columns))
    }

    private func choice<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View
    {
        VStack(alignment: .leading, spacing: Metrics.gapWide) {
            Text(title).font(.ui(TextSize.body, weight: .semibold))
            content()
        }
    }

    private func binding(_ setting: Setting<String>) -> Binding<String> {
        Binding(get: { app.settings[setting] }, set: { app.settings.set(setting, $0) })
    }
}
