import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WebKit

extension Builtins {
    /// Settings › Browser: the sites where agents use the user's login.
    static func browserSettings(_ app: AppModel) -> SettingsSection {
        SettingsSection(
            id: "browser", title: "Browser", icon: "safari", specs: [],
            custom: { AnyView(BrowserSettings(app: app)) },
            keywords: ["Login", "Cookies", "Sign Out", "Your login for agents", "--shared"], order: 74)
    }
}

/// The sites where agents use the user's login from Kelp's browser (`AgentSites`), each with the chat it was first
/// allowed for and when. Remove takes one away; the user stays signed in there. Sign Out of All Sites empties Kelp's
/// browser, for the user too.
struct BrowserSettings: View {
    let app: AppModel

    var body: some View {
        let entries = AgentSites.entries(app.settings[SettingKeys.agentSites])
        TitledSection("Your login for agents") {
            Text("On these sites agents use your login from Kelp’s browser; elsewhere they get a page of their own.")
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("No sites yet. When an agent needs your login on a site, its row asks you.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.site) { entry in
                LabeledContent {
                    Button("Remove") { remove(entry.site) }
                } label: {
                    Text(verbatim: entry.site)
                    Text(Self.allowed(entry)).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
            }
        }
        TitledSection("Kelp’s browser") {
            LabeledContent {
                Button("Sign Out of All Sites…") { Task { await signOut() } }
            } label: {
                Text("Cookies and site data")
                Text("Your logins in Kelp’s browser, yours and the ones agents use.")
                    .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            }
        }
    }

    /// "Allowed for “read x posts” · Nov 27".
    static func allowed(_ entry: AgentSites.Entry) -> String {
        let day = entry.at.formatted(date: .abbreviated, time: .omitted)
        return entry.chat.isEmpty
            ? String(localized: "Allowed \(day)") : String(localized: "Allowed for “\(entry.chat)” · \(day)")
    }

    private func remove(_ site: String) {
        let list = app.settings[SettingKeys.agentSites]
        app.settings.set(SettingKeys.agentSites.key, .array(AgentSites.removing(site, from: list)))
    }

    private func signOut() async {
        guard
            await confirm(
                String(localized: "Sign out of all sites in Kelp’s browser?"),
                detail: String(
                    localized: "Its cookies and site data go, for you and for agents. Kelp’s own pages stay."),
                action: String(localized: "Sign Out"), destructive: true)
        else { return }
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
