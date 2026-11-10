import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// Account profiles for the agents whose manifests have them (Claude Code, Codex): each has its own config dir
/// (`AgentHome`'s variable), so logins stay side by side and switching is just a different environment.
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
    /// nil, with a banner, when the settings can't be read: a list saved after an empty one read in its place would
    /// write the profiles there are over.
    static func load(_ app: AppModel) async -> [AccountProfile]? {
        guard let settings = await app.call(SettingsGet()) else { return nil }
        guard let saved = settings[SettingKeys.accounts.key] else { return [] }
        do { return try saved.decode([AccountProfile].self) } catch {
            let why = error.localizedDescription
            Banner.show(String(localized: "Kelp can't read the accounts in settings.json: \(why)"), style: .error)
            return nil
        }
    }
    static func save(_ app: AppModel, _ list: [AccountProfile]) async {
        do { await app.call(SettingsSet(key: SettingKeys.accounts.key, value: try JSONValue.from(list))) } catch {
            Banner.show(AppModel.message(error), style: .error)
        }
    }
}

struct AccountsSettings: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    @State private var profiles: [AccountProfile] = []
    /// Read: until then (or when that failed) nothing is saved, so no list overwrites the one in settings.json.
    @State private var loaded = false
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
                    ForEach(app.catalog.all.filter(\.profiles), id: \.id) { Text($0.name).tag($0.id) }
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
                .disabled(!loaded || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Log In…") { login() }.disabled(selection == nil)
                Button("Remove…") { remove() }.disabled(!loaded || selection == nil)
            }
            Text(
                "Log in once per profile; afterwards pick the account when starting an agent. Usage and limits per account show in Agents › Usage."
            )
            .font(.ui(11)).foregroundStyle(.secondary)
        }
        .task {
            guard let read = await Accounts.load(app) else { return }
            profiles = read
            loaded = true
        }
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
