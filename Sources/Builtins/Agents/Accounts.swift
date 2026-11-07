import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

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
        // A banner when the settings can't be read.
        let saved = await app.call(SettingsGet())?[SettingKeys.accounts.key]
        return (try? saved?.decode([AccountProfile].self)) ?? []
    }
    static func save(_ app: AppModel, _ list: [AccountProfile]) async {
        await app.call(SettingsSet(key: SettingKeys.accounts.key, value: (try? JSONValue.from(list)) ?? .array([])))
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
        Section("Accounts") {
            if profiles.isEmpty {
                Text("No profiles yet: agents use their own login.").foregroundStyle(.secondary)
            } else {
                Table(profiles, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Agent") { Text(app.catalog.name($0.agent)) }.width(100)
                    TableColumn("Config folder", value: \.dir)
                }
            }
            HStack {
                Picker("", selection: $newAgent) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                }.labelsHidden().fixedSize()
                TextField("Profile name", text: $newName, prompt: Text("Profile name")).labelsHidden().textFieldStyle(
                    .roundedBorder
                ).frame(minWidth: 110)
                Button("Add") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    profiles.append(
                        AccountProfile(
                            name: name, agent: newAgent, dir: AccountProfile.defaultDir(agent: newAgent, name: name)))
                    newName = ""
                    Task { await Accounts.save(app, profiles) }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Log In…") { login() }.disabled(selection == nil)
                Button("Remove…") { remove() }.disabled(selection == nil)
            }
            Text(
                "Log in once per profile; afterwards pick the account when starting an agent. Usage and limits per account show in Agents › Usage."
            )
            .font(.ui(11)).foregroundStyle(.secondary)
        }
        .task { profiles = await Accounts.load(app) }
    }

    /// Opens the agent in that profile so the user can run its login flow once.
    private func login() {
        guard let profile = profiles.first(where: { $0.id == selection }) else { return }
        guard let wid = app.workbench.workspaceId else {
            Banner.show(String(localized: "Open a chat to log in to \(profile.name) there."))
            return
        }
        Task {
            guard
                let session = await app.call(
                    SessionCreate(
                        worktreeId: wid, agent: profile.agent, title: String(localized: "Log in: \(profile.name)"),
                        profile: profile.name))
            else { return }
            app.upsert(session)
            app.workbench.open(TabURI.session(session.id))
            app.workbench.bringToFront()
        }
    }

    /// Kelp forgets the profile; its folder, with the login in it, stays where it is.
    private func remove() {
        guard let profile = profiles.first(where: { $0.id == selection }) else { return }
        Task {
            let question = NSAlert(
                question: String(localized: "Remove the profile “\(profile.name)”?"),
                detail: String(localized: "Its login stays in \(profile.dir)."), action: String(localized: "Remove"))
            guard await runSheet(question) == .alertFirstButtonReturn else { return }
            profiles.removeAll { $0.id == profile.id }
            await Accounts.save(app, profiles)
        }
    }
}
