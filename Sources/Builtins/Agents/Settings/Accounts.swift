import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// An account profile for an agent whose manifest supports profiles (Claude Code, Codex). Each profile has its own
/// config folder, set through the variable that `AgentHome` names, so logins sit side by side and switching accounts
/// just means a different environment.
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
    /// Reads the saved profiles. Returns nil and shows a banner when the settings can't be read, because saving after
    /// an empty list was read in place of the real one would overwrite the existing profiles. It reads from the daemon,
    /// not the app's copy of the settings, because that copy may come from a read that failed.
    static func load(_ app: AppModel) async -> [AccountProfile]? {
        guard let settings = await app.call(SettingsGet()) else { return nil }
        guard let saved = settings[SettingKeys.accounts.key] else { return [] }
        do { return try saved.decode([AccountProfile].self) } catch {
            let why = error.localizedDescription
            Banner.show(String(localized: "Kelp can’t read the accounts in settings.json: \(why)"), style: .error)
            return nil
        }
    }
    /// Saves the list the way every setting is saved (`SettingsStore.set`). The change shows at once, and a banner says
    /// so if settings.json refused it.
    static func save(_ app: AppModel, _ list: [AccountProfile]) {
        do { app.settings.set(SettingKeys.accounts, try list.map { try JSONValue.from($0) }) } catch {
            Banner.show(AppModel.message(error), style: .error)
        }
    }
}

struct AccountsSettings: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    @State private var profiles: [AccountProfile] = []
    /// True once the profiles were read. Until then, or when the read failed, nothing is saved, so no list overwrites
    /// the one in settings.json.
    @State private var loaded = false
    @State private var selection: AccountProfile.ID?
    @State private var newName = ""
    @State private var newAgent = Session.claudeAgent

    var body: some View {
        TitledSection("Accounts") {
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
                Picker("Agent", selection: $newAgent) {
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
                    Accounts.save(app, profiles)
                }
                .disabled(!loaded || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Log In…") { login() }.disabled(selection == nil)
                Button("Remove…") { remove() }.disabled(!loaded || selection == nil)
            }
            Text(
                "Log in once per profile; afterwards pick the account when starting an agent. Usage and limits per account show in Window › Usage."
            )
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
        }
        .task {
            guard let read = await Accounts.load(app) else { return }
            profiles = read
            loaded = true
        }
    }

    /// Opens the agent in the selected profile, so the user can run the agent's login flow once.
    private func login() {
        guard let profile = profiles.first(where: { $0.id == selection }) else { return }
        guard let wid = app.workbench.workspaceId else {
            Banner.show(String(localized: "Open a chat to log in to \(profile.name) there."))
            return
        }
        Task {
            guard
                let session = await app.call(
                    app.workbench.sized(
                        SessionCreate(
                            worktreeId: wid, agent: profile.agent, title: String(localized: "Log in: \(profile.name)"),
                            profile: profile.name)))
            else { return }
            app.upsert(session)
            app.workbench.open(TabURI.session(session.id))
            app.workbench.bringToFront()
        }
    }

    /// Makes Kelp forget the profile. The profile's folder, with the login in it, stays where it is.
    private func remove() {
        guard let profile = profiles.first(where: { $0.id == selection }) else { return }
        Task {
            guard
                await confirm(
                    String(localized: "Remove the profile “\(profile.name)”?"),
                    detail: String(localized: "Its login stays in \(profile.dir)."), action: String(localized: "Remove")
                )
            else { return }
            profiles.removeAll { $0.id == profile.id }
            Accounts.save(app, profiles)
        }
    }
}
