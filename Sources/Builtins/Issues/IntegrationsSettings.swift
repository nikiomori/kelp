import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// One row a service, so what's connected reads at a glance; fields that are filled in once open in a sheet.
struct IntegrationsSettings: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    @State private var gh = CLIState()
    @State private var glab = CLIState()
    @State private var linear = Connection()
    @State private var jira = Connection()
    @State private var bitbucket = Connection()
    @State private var connecting: Account?

    /// What a service with credentials of its own says about itself.
    private struct Connection {
        var status = String(localized: "Checking…"), on = false
    }

    var body: some View {
        Group {
            Section("Code hosting") {
                cliRow(
                    "GitHub", gh,
                    "Through the GitHub CLI and its login. Project boards need `gh auth refresh -s read:project`.")
                cliRow("GitLab", glab, "Through the GitLab CLI (glab) and its login, self-managed hosts too.")
                linkRow(.bitbucket, bitbucket, "For repos whose origin is on bitbucket.org.")
            }
            Section("Issues") {
                linkRow(.jira, jira, "Issues from your Jira site.")
                linkRow(.linear, linear, "Issues from your Linear workspace.")
            }
        }
        .sheet(item: $connecting) { a in ConnectSheet(account: a) { await connect(a, $0) } }
        .task {
            let linearStatus = await app.call(LinearStatus())
            linear = Connection(
                status: linearStatus?.connected == true
                    ? String(localized: "Connected as \(linearStatus?.name ?? "")") : off,
                on: linearStatus?.connected == true)
            let jiraStatus = await app.call(JiraStatus())
            let inJira = String(localized: "Connected to \(jiraStatus?.site ?? "") as \(jiraStatus?.name ?? "")")
            jira = Connection(status: jiraStatus?.connected == true ? inJira : off, on: jiraStatus?.connected == true)
            let bitbucketStatus = await app.call(BitbucketStatus())
            bitbucket = Connection(
                status: bitbucketStatus?.connected == true ? String(localized: "Credentials saved") : off,
                on: bitbucketStatus?.connected == true)
            await check()
        }
    }

    private var off: String { String(localized: "Not connected") }

    /// What gh or glab can do now, and the button that sets it up in a terminal tab.
    struct CLIState { var status = String(localized: "Checking…"), on = false, setup: Forge.Setup? }

    private func row(
        _ name: String, on: Bool, status: String, about: LocalizedStringKey, @ViewBuilder actions: () -> some View
    ) -> some View {
        LabeledContent {
            HStack {
                Circle().strokeBorder(on ? Color.clear : Color.secondary, lineWidth: 1.5)
                    .background(Circle().fill(on ? Color.green : .clear)).frame(width: 8, height: 8)
                    .accessibilityHidden(true)   // the status beside it says the same in words
                Text(status).foregroundStyle(.secondary)
                actions()
            }
        } label: {
            Text(name)
            Text(about)
        }
    }

    private func cliRow(_ name: String, _ cli: CLIState, _ about: LocalizedStringKey) -> some View {
        row(name, on: cli.on, status: cli.status, about: about) {
            if let setup = cli.setup {
                Button(setup.title) { Forge.run(setup, in: app) }.help(setup.command)
                Button("Check Again") { Task { await check() } }
            }
        }
    }

    private func linkRow(_ account: Account, _ connection: Connection, _ about: LocalizedStringKey) -> some View {
        row(account.title, on: connection.on, status: connection.status, about: about) {
            if connection.on {
                Button("Disconnect") { Task { await disconnect(account) } }
            } else {
                Button("Connect…") { connecting = account }
            }
        }
    }

    private func disconnect(_ account: Account) async {
        switch account {
        case .jira:
            if await app.call(JiraSetCredentials(site: "", email: "", token: "")) != nil {
                jira = Connection(status: off)
            }
        case .bitbucket:
            if await app.call(BitbucketSetCredentials(user: "", token: "")) != nil {
                bitbucket = Connection(status: off)
            }
        case .linear: if await app.call(LinearSetKey(key: "")) != nil { linear = Connection(status: off) }
        }
    }

    /// The sheet's values, in its fields' order. False keeps it open: `call` has said what went wrong.
    private func connect(_ account: Account, _ values: [String]) async -> Bool {
        switch account {
        case .jira:
            guard let me = await app.call(JiraSetCredentials(site: values[0], email: values[1], token: values[2]))
            else { return false }
            jira = Connection(status: String(localized: "Connected as \(me?.name ?? "")"), on: true)
        case .bitbucket:
            guard await app.call(BitbucketSetCredentials(user: values[0], token: values[1])) != nil else {
                return false
            }
            bitbucket = Connection(status: String(localized: "Credentials saved"), on: true)
        case .linear:
            guard let me = await app.call(LinearSetKey(key: values[0])) else { return false }
            linear = Connection(status: String(localized: "Connected as \(me?.name ?? "")"), on: true)
        }
        return true
    }

    private func check() async {
        func state(_ status: GitHubStatus.Result?, _ cli: String) -> CLIState {
            guard let status else { return CLIState(status: String(localized: "Couldn't check")) }
            if !status.installed {
                return CLIState(status: String(localized: "Not installed"), setup: Forge.install(cli))
            }
            if let user = status.user { return CLIState(status: String(localized: "Signed in as \(user)"), on: true) }
            return CLIState(status: String(localized: "Not signed in"), setup: Forge.signIn(cli))
        }
        gh = state(await app.call(GitHubStatus()), "gh")
        glab = state(await app.call(GitLabStatus()), "glab")
    }
}

/// A service Kelp logs in to with a token of its own.
private enum Account: String, Identifiable {
    case jira, bitbucket, linear
    var id: String { rawValue }
    var title: String { rawValue == "jira" ? "Jira" : rawValue == "linear" ? "Linear" : "Bitbucket" }

    struct Field { let title: LocalizedStringKey, prompt: LocalizedStringKey, secret: Bool }
    var fields: [Field] {
        switch self {
        case .jira:
            [
                Field(title: "Site", prompt: "acme.atlassian.net", secret: false),
                Field(title: "Email", prompt: "you@acme.com", secret: false),
                Field(title: "API token", prompt: "Paste the token", secret: true)
            ]
        case .bitbucket:
            [
                Field(title: "Username or email", prompt: "you@acme.com", secret: false),
                Field(title: "API token / app password", prompt: "Paste the token", secret: true)
            ]
        case .linear: [Field(title: "Personal API key", prompt: "Paste the key", secret: true)]
        }
    }
    var help: LocalizedStringKey {
        switch self {
        case .jira: "API token from id.atlassian.com › Security. Stored in your login keychain."
        case .bitbucket: "Used for pull requests in repos whose origin is on bitbucket.org."
        case .linear: "Create a key in Linear › Settings › Security & access. It's stored in your login keychain."
        }
    }
}

private struct ConnectSheet: View {
    let account: Account
    let connect: ([String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gapWide) {
            Text("Connect \(account.title)").font(.ui(TextSize.body, weight: .semibold))
            Form {
                ForEach(values.indices, id: \.self) { index in
                    let field = account.fields[index]
                    if field.secret {
                        SecureField(field.title, text: $values[index], prompt: Text(field.prompt))
                    } else {
                        TextField(field.title, text: $values[index], prompt: Text(field.prompt))
                    }
                }
            }
            .formStyle(.columns)
            Text(account.help).font(.ui(TextSize.caption)).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    busy = true
                    Task {
                        if await connect(values) { dismiss() }
                        busy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || values.contains(where: \.isEmpty))
            }
        }
        .padding(Metrics.sheetInset)
        .frame(width: Metrics.sheetWidth)
        .onAppear { values = account.fields.map { _ in "" } }
    }
}
