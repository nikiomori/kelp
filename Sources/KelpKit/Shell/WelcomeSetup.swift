import SwiftUI
import DesignKit

/// The first-run welcome's three choices: the theme, the text size and the agent a new chat starts. Each applies as it's
/// picked and is the same tiles as in Settings, where it can be changed later; the welcome's buttons are the way on.
struct WelcomeSetup: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let agents = Self.firstAgents(app.catalog.installed(app.catalog.all).map(\.id), current: app.settings.string("agents.default"))
        VStack(alignment: .leading, spacing: Metrics.sheetInset) {
            choice("Theme") { ThemeGallery(selection: binding("workbench.theme", "auto"), kelpOnly: true) }
            choice("Text size") {
                PictureGrid(key: "workbench.textSize", options: ["normal", "large", "larger"], selection: binding("workbench.textSize", "normal"),
                            label: { SettingRow.label("workbench.textSize", $0, app) })
            }
            if !agents.isEmpty {
                choice("Default agent") {
                    PictureGrid(key: "agents.default", options: agents,
                                selection: binding("agents.default", "claude"), label: { SettingRow.label("agents.default", $0, app) })
                }
            }
        }
        .frame(width: 560)   // the five theme cards in one row
    }

    /// One row at most, the chosen one first: not a wall of every agent installed (Settings has them all).
    static func firstAgents(_ installed: [String], current: String?) -> [String] {
        let known = ["claude", "codex", "gemini", "cursor", "copilot", "opencode"]
        var picked = known.filter(installed.contains) + installed.filter { !known.contains($0) }
        if let current, installed.contains(current) { picked.removeAll { $0 == current }; picked.insert(current, at: 0) }
        return Array(picked.prefix(PictureGrid.columns))
    }

    private func choice<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gapWide) {
            Text(title).font(.headline)
            content()
        }
    }

    private func binding(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { app.settings.string(key) ?? fallback }, set: { app.settings.set(key, .string($0)) })
    }
}
