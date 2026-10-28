import AppKit
import SwiftUI
import Core
import KelpKit

struct IntegrationsSettings: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    @State private var key = ""
    @State private var linearStatus = String(localized: "Checking…")
    @State private var gh = CLIState()
    @State private var glab = CLIState()
    @State private var jiraStatus = String(localized: "Checking…")
    @State private var jiraSite = ""
    @State private var jiraEmail = ""
    @State private var jiraToken = ""
    @State private var bbStatus = ""
    @State private var bbUser = ""
    @State private var bbToken = ""
    /// Connected: the status and Disconnect; not: the fields and Connect. One button, the one that does something now.
    @State private var linearOn = false
    @State private var jiraOn = false
    @State private var bbOn = false
    // Sections of the settings page's own form: a form of its own here drew a card inside its card.
    var body: some View {
        Group {
            Section("GitHub") {
                cliRow(gh)
                Text("Kelp uses the GitHub CLI and its login. Project boards need `gh auth refresh -s read:project`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("GitLab") {
                cliRow(glab)
                Text("Merge requests, issues and pipelines through the GitLab CLI (glab) and its login, self-managed hosts too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Jira") {
                if jiraOn {
                    connected(jiraStatus) { Task {
                        if await app.call(JiraSetCredentials(site: "", email: "", token: "")) != nil { jiraStatus = off; jiraOn = false }
                    } }
                } else {
                    TextField("Site", text: $jiraSite, prompt: Text("acme.atlassian.net")).textFieldStyle(.roundedBorder)
                    TextField("Email", text: $jiraEmail, prompt: Text("you@acme.com")).textFieldStyle(.roundedBorder)
                    SecureField("API token", text: $jiraToken).textFieldStyle(.roundedBorder)
                    connect(disabled: jiraSite.isEmpty || jiraEmail.isEmpty || jiraToken.isEmpty) { Task {
                        if let r = await app.call(JiraSetCredentials(site: jiraSite, email: jiraEmail, token: jiraToken)) {
                            jiraStatus = String(localized: "Connected as \(r?.name ?? "")")
                            jiraToken = ""
                            jiraOn = true
                        }
                    } }
                }
                Text("API token from id.atlassian.com › Security. Stored in your login keychain.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Bitbucket") {
                if bbOn {
                    connected(bbStatus) { Task {
                        if await app.call(BitbucketSetCredentials(user: "", token: "")) != nil { bbStatus = off; bbOn = false }
                    } }
                } else {
                    TextField("Username or email", text: $bbUser).textFieldStyle(.roundedBorder)
                    SecureField("API token / app password", text: $bbToken).textFieldStyle(.roundedBorder)
                    connect(disabled: bbUser.isEmpty || bbToken.isEmpty) { Task {
                        if await app.call(BitbucketSetCredentials(user: bbUser, token: bbToken)) != nil {
                            bbStatus = String(localized: "Credentials saved")
                            bbToken = ""
                            bbOn = true
                        }
                    } }
                }
                Text("Used for pull requests in repos whose origin is on bitbucket.org.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Linear") {
                if linearOn {
                    connected(linearStatus) { Task {
                        if await app.call(LinearSetKey(key: "")) != nil { linearStatus = off; linearOn = false }
                    } }
                } else {
                    SecureField("Personal API key", text: $key).textFieldStyle(.roundedBorder)
                    connect(disabled: key.isEmpty) { Task { await connect() } }
                }
                Text("Create a key in Linear › Settings › Security & access. It's stored in your login keychain.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            let s = await app.call(LinearStatus())
            linearOn = s?.connected == true
            linearStatus = linearOn ? String(localized: "Connected as \(s?.name ?? "")") : off
            let j = await app.call(JiraStatus())
            jiraOn = j?.connected == true
            jiraStatus = jiraOn ? String(localized: "Connected to \(j?.site ?? "") as \(j?.name ?? "")") : off
            bbOn = (await app.call(BitbucketStatus()))?.connected == true
            bbStatus = bbOn ? String(localized: "Credentials saved") : off
            await check()
        }
    }

    private var off: String { String(localized: "Not connected") }

    /// Who it's connected as, and Disconnect beside it.
    private func connected(_ status: String, disconnect: @escaping () -> Void) -> some View {
        HStack {
            Text(status).foregroundStyle(.secondary)
            Spacer()
            Button("Disconnect", action: disconnect)
        }
    }

    /// Connect, at the trailing edge under the fields, as a form's button.
    private func connect(disabled: Bool, _ run: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Connect", action: run).disabled(disabled)
        }
    }

    /// What gh or glab can do now, and the button that sets it up in a terminal tab.
    struct CLIState { var status = String(localized: "Checking…"), setup: Forge.Setup? }

    private func cliRow(_ c: CLIState) -> some View {
        HStack {
            Text(c.status).foregroundStyle(.secondary)
            Spacer()
            if let s = c.setup {
                Button(s.title) { Forge.run(s, in: app) }.help(s.command)
                Button("Check Again") { Task { await check() } }
            }
        }
    }

    private func check() async {
        func state(_ r: GitHubStatus.Result?, _ cli: String, _ site: String) -> CLIState {
            guard let r else { return CLIState(status: String(localized: "Couldn't check")) }
            if !r.installed { return CLIState(status: String(localized: "\(site) CLI isn't installed"), setup: Forge.install(cli)) }
            if let u = r.user { return CLIState(status: String(localized: "Signed in as \(u)")) }
            return CLIState(status: String(localized: "\(site) CLI isn't signed in (or \(site) can't be reached)"), setup: Forge.signIn(cli))
        }
        gh = state(await app.call(GitHubStatus()), "gh", "GitHub")
        glab = state(await app.call(GitLabStatus()), "glab", "GitLab")
    }
    private func connect() async {
        if let me = await app.call(LinearSetKey(key: key)) {
            linearStatus = String(localized: "Connected as \(me?.name ?? "")")
            key = ""
            linearOn = true
        }
    }
}
