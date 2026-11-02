import AppKit
import SwiftUI
import Core
import WorkbenchKit
import KelpKit

/// Account profiles for Claude Code / Codex: each has its own config dir (CLAUDE_CONFIG_DIR / CODEX_HOME),
/// so logins stay side by side and switching is just a different environment.
struct AccountProfile: Codable, Hashable, Identifiable {
    var name: String
    var agent: String
    var dir: String
    var id: String { agent + "/" + name }
    static func defaultDir(agent: String, name: String) -> String {
        Paths.root.appendingPathComponent("accounts/\(agent)/\(name)").path
    }
}

@MainActor
enum Accounts {
    static func load(_ app: AppModel) async -> [AccountProfile] {
        let saved = await app.call(SettingsGet())?["accounts.profiles"]   // a banner when the settings can't be read
        return (try? saved?.decode([AccountProfile].self)) ?? []
    }
    static func save(_ app: AppModel, _ list: [AccountProfile]) async {
        await app.call(SettingsSet(key: "accounts.profiles", value: (try? JSONValue.from(list)) ?? .array([])))
    }
}

struct AccountsSettings: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    @State private var profiles: [AccountProfile] = []
    @State private var selection: AccountProfile.ID?
    @State private var newName = ""
    @State private var newAgent = "claude"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(profiles, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Agent", value: \.agent).width(80)
                TableColumn("Config folder", value: \.dir)
            }
            HStack {
                Picker("", selection: $newAgent) { Text("Claude Code").tag("claude"); Text("Codex").tag("codex") }.labelsHidden().frame(width: 130)
                TextField("Profile name (e.g. work)", text: $newName).frame(width: 200)
                Button("Add") {
                    let n = newName.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
                    profiles.append(AccountProfile(name: n, agent: newAgent, dir: AccountProfile.defaultDir(agent: newAgent, name: n)))
                    newName = ""; Task { await Accounts.save(app, profiles) }
                }
                Spacer()
                Button("Log In…") { login() }.disabled(selection == nil)
                Button("Remove…") { remove() }.disabled(selection == nil)
            }
            Text("Log in once per profile; afterwards pick the account when starting an agent. Usage and limits per account show in Agents › Usage.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .task { profiles = await Accounts.load(app) }
    }

    /// Opens the agent in that profile so the user can run its login flow once.
    private func login() {
        guard let p = profiles.first(where: { $0.id == selection }) else { return }
        guard let wid = app.workbench.workspaceId else {
            Banner.show(String(localized: "Open a chat to log in to \(p.name) there."))
            return
        }
        Task {
            guard let s = await app.call(SessionCreate(worktreeId: wid, agent: p.agent, title: String(localized: "Log in: \(p.name)"),
                                                                   profile: p.name)) else { return }
            app.upsert(s); app.workbench.open(TabURI.session(s.id))
            app.workbench.bringToFront()
        }
    }

    /// Kelp forgets the profile; its folder, with the login in it, stays where it is.
    private func remove() {
        guard let p = profiles.first(where: { $0.id == selection }) else { return }
        Task {
            guard await confirm(String(localized: "Remove the profile “\(p.name)”?"),
                                detail: String(localized: "Its login stays in \(p.dir)."), action: String(localized: "Remove")) else { return }
            profiles.removeAll { $0.id == p.id }
            await Accounts.save(app, profiles)
        }
    }
}
