import AppKit
import SwiftUI
import Core
import DesignKit
import KelpKit

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
                cliRow("GitHub", gh, "Through the GitHub CLI and its login. Project boards need `gh auth refresh -s read:project`.")
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
            let s = await app.call(LinearStatus())
            linear = Connection(status: s?.connected == true ? String(localized: "Connected as \(s?.name ?? "")") : off, on: s?.connected == true)
            let j = await app.call(JiraStatus())
            let inJira = String(localized: "Connected to \(j?.site ?? "") as \(j?.name ?? "")")
            jira = Connection(status: j?.connected == true ? inJira : off, on: j?.connected == true)
            let b = await app.call(BitbucketStatus())
            bitbucket = Connection(status: b?.connected == true ? String(localized: "Credentials saved") : off, on: b?.connected == true)
            await check()
        }
    }

    private var off: String { String(localized: "Not connected") }

    /// What gh or glab can do now, and the button that sets it up in a terminal tab.
    struct CLIState { var status = String(localized: "Checking…"), on = false, setup: Forge.Setup? }

    private func row(_ name: String, on: Bool, status: String, about: LocalizedStringKey, @ViewBuilder actions: () -> some View) -> some View {
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

    private func cliRow(_ name: String, _ c: CLIState, _ about: LocalizedStringKey) -> some View {
        row(name, on: c.on, status: c.status, about: about) {
            if let s = c.setup {
                Button(s.title) { Forge.run(s, in: app) }.help(s.command)
                Button("Check Again") { Task { await check() } }
            }
        }
    }

    private func linkRow(_ a: Account, _ l: Connection, _ about: LocalizedStringKey) -> some View {
        row(a.title, on: l.on, status: l.status, about: about) {
            if l.on { Button("Disconnect") { Task { await disconnect(a) } } } else { Button("Connect…") { connecting = a } }
        }
    }

    private func disconnect(_ a: Account) async {
        switch a {
        case .jira: if await app.call(JiraSetCredentials(site: "", email: "", token: "")) != nil { jira = Connection(status: off) }
        case .bitbucket: if await app.call(BitbucketSetCredentials(user: "", token: "")) != nil { bitbucket = Connection(status: off) }
        case .linear: if await app.call(LinearSetKey(key: "")) != nil { linear = Connection(status: off) }
        }
    }

    /// The sheet's values, in its fields' order. False keeps it open: `call` has said what went wrong.
    private func connect(_ a: Account, _ v: [String]) async -> Bool {
        switch a {
        case .jira:
            guard let r = await app.call(JiraSetCredentials(site: v[0], email: v[1], token: v[2])) else { return false }
            jira = Connection(status: String(localized: "Connected as \(r?.name ?? "")"), on: true)
        case .bitbucket:
            guard await app.call(BitbucketSetCredentials(user: v[0], token: v[1])) != nil else { return false }
            bitbucket = Connection(status: String(localized: "Credentials saved"), on: true)
        case .linear:
            guard let me = await app.call(LinearSetKey(key: v[0])) else { return false }
            linear = Connection(status: String(localized: "Connected as \(me?.name ?? "")"), on: true)
        }
        return true
    }

    private func check() async {
        func state(_ r: GitHubStatus.Result?, _ cli: String) -> CLIState {
            guard let r else { return CLIState(status: String(localized: "Couldn't check")) }
            if !r.installed { return CLIState(status: String(localized: "Not installed"), setup: Forge.install(cli)) }
            if let u = r.user { return CLIState(status: String(localized: "Signed in as \(u)"), on: true) }
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
        case .jira: [Field(title: "Site", prompt: "acme.atlassian.net", secret: false), Field(title: "Email", prompt: "you@acme.com", secret: false),
                     Field(title: "API token", prompt: "Paste the token", secret: true)]
        case .bitbucket: [Field(title: "Username or email", prompt: "you@acme.com", secret: false),
                          Field(title: "API token / app password", prompt: "Paste the token", secret: true)]
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
            Text("Connect \(account.title)").font(.ui(13, weight: .semibold))
            Form {
                ForEach(values.indices, id: \.self) { i in
                    let f = account.fields[i]
                    if f.secret {
                        SecureField(f.title, text: $values[i], prompt: Text(f.prompt))
                    } else {
                        TextField(f.title, text: $values[i], prompt: Text(f.prompt))
                    }
                }
            }
            .formStyle(.columns)
            Text(account.help).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
