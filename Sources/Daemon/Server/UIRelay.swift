import Core
import Foundation

/// Agents → app: `kelp open`, `kelp ui` etc. call `ui.*`; the daemon relays them to the app as `event.ui`.
/// The app publishes what it shows (`ui.publish`) so agents can read it back (`ui.state`), and keeps what it restores
/// (each workspace's layout, the sidebar's order…) in the database with `state.*`, so every KELP_HOME has its own.
extension UIPublish: Handled {
    static var inOrder: Bool { true }
    /// Only Kelp's window says what's on screen (and gets event.ui): an agent can't stand in for it.
    var onlyFromKelp: String? { "Only Kelp's window publishes its state." }
    func handle(_ clients: Clients, conn: Int) throws -> Done {
        clients.publishUI(state, from: conn)
        return Done()
    }
}

extension UIStateGet: Handled { func handle(_ clients: Clients) throws -> ShownUI { clients.uiState } }

extension UIOpen: Handled {
    /// A terminal or an agent the app starts is nobody's: one an agent asks for comes from `kelp session new`, which makes it its own.
    /// Its scheme as the app reads it (`TabURI.scheme`: any case), not as it's spelled: `TERMINAL:` runs a command too.
    private var scheme: String { uri.firstIndex(of: ":").map { uri[..<$0].lowercased() } ?? "file" }
    var notForAgents: String? {
        if ["terminal", "agent"].contains(scheme) {
            return "An agent starts terminals and agents with `kelp session new`, which keeps them its own."
        }
        // A plain page tab has the user's cookies (and `kelp shot` sees it): an agent's page has its own. A local page
        // (`preview:`) has them too, and it can go on to any site.
        if ["http", "https", "preview"].contains(scheme) {
            return "A page tab opened this way is logged in as the user: open it with `kelp browser open <url>` "
                + "(a local page: `kelp browser open preview:<path>`), which gives it cookies of its own."
        }
        return nil
    }
    /// A session's tab shows its screen, a subagent's its journal: an agent's own, or one it started (`named(by:)` sees
    /// bare ids only).
    var shows: String? {
        guard ["session", "subagent"].contains(scheme) else { return nil }
        return lead
    }
    /// The workspace a tab of one names in its body (`db:<workspace>/<name>`, `diff:<workspace>?…`): the app opens it as
    /// the user, so it's held as that field would be. Else `worktreeId` (none named: the one on screen, where it shows a
    /// file or a page). A database's tab names its workspace as the tab itself reads it (`DatabaseTabURI.parts`, which
    /// reads past a `?` or `/` before the id), and which database it may be is the fence's (`AgentRules.allow`).
    var inWorkspace: String? {
        if let database = DatabaseTabURI.parts(uri) { return database.worktree }
        let named = shows == nil && UUID(uuidString: lead) != nil ? lead : nil
        return named ?? worktreeId
    }
    /// The id at the start of the body, read as the app reads it: tabs take their address apart with `URLComponents`,
    /// which decodes `%31…` to `1…`, so an id spelled that way is still the id.
    private var lead: String {
        let body = String(uri.drop { $0 != ":" }.dropFirst())
        return String((body.removingPercentEncoding ?? body).prefix { $0.isHexDigit || $0 == "-" })
    }
    func handle(_ clients: Clients) throws -> Delivered {
        if let split, split != "right", split != "down" {
            throw RPCError.invalidParams("split must be \"right\" or \"down\"")
        }
        return try clients.relay(UIEvent(self))
    }
}

extension UICommand: Handled {
    var notForAgents: String? {
        Self.forAgents.contains(id)
            ? nil
            : "“\(id)” is the user's to run: an agent runs only commands that show something, and starts sessions with `kelp session`."
    }
    func handle(_ clients: Clients) throws -> Delivered { try clients.relay(UIEvent(self)) }
}

/// To the app, which does it in a browser tab and answers with `ui.browser.reply`; this waits for that answer.
/// A subagent's command says whose it is (`args.subagent`): Claude Code's hook told which subagent runs it.
extension UIBrowser: AsyncHandled {
    var inWorkspace: String? { worktreeId ?? "" }   // none named: the one on screen, which needn't be the agent's
    func handle(_ relay: BrowserRelay) async throws -> JSONValue {
        let ui = relay.ui
        ui.browserUsed(in: worktreeId)   // an agent wants pages here, whether or not the app is there to show one
        let clients = ui.clients, apps = clients.apps
        guard !apps.isEmpty else { throw RPCError.internalError("The Kelp app isn't running") }
        var call = self
        if case .object(var fields) = args, let session = fields["session"]?.string,
            let subagent = relay.sessions.existing(session)?.browsing(Self.words(action, args))
        {
            fields["subagent"] = .string(subagent)
            call.args = .object(fields)
        }
        let request = UUID().uuidString
        return try await clients.reply(to: request, from: apps, within: Self.wait) {
            clients.notify(UIBrowserEvent(call, request: request), to: apps)
        }
    }

    /// What the command line says after `kelp browser`: `click e12`, `open http://localhost:3000`.
    static func words(_ action: String, _ args: JSONValue?) -> String {
        ([action] + ["ref", "key", "url"].compactMap { args?[$0]?.string }.prefix(1)).joined(separator: " ")
    }
}

/// What answers `ui.browser`: the window it goes to, and the sessions that say which subagent asks.
struct BrowserRelay: DaemonService {
    let ui: UIStore, sessions: Sessions
    static func of(_ daemon: Daemon) -> BrowserRelay { BrowserRelay(ui: .of(daemon), sessions: daemon.sessions) }
}

extension UIBrowserReply: Handled {
    var onlyFromKelp: String? { "Only Kelp's window answers browser requests." }
    func handle(_ clients: Clients) throws -> Done {
        clients.answer(request, error.map { .failure(RPCError.internalError($0)) } ?? .success(result ?? .null))
        return Done()
    }
}

extension Clients {
    /// To every Kelp window as `event.ui`.
    fileprivate func relay(_ event: UIEvent) throws -> Delivered {
        let apps = apps
        guard !apps.isEmpty else { throw RPCError.internalError("The Kelp app isn't running") }
        notify(event, to: apps)
        return Delivered(delivered: apps.count)
    }
}

/// What Kelp's window keeps in the daemon (`state.*`), and who may write it.
struct UIStore {
    let store: Store, clients: Clients
}

extension StateGet: Handled {
    static var quick: Bool { true }
    func handle(_ ui: UIStore) throws -> JSONValue {
        if let prefix {
            var all = try ui.store.uiState(prefix: prefix)
            // daemonState's, never a stale copy an older daemon left in uiState (or none, where the trust was taken back)
            for key in Store.trustKeys where key.hasPrefix(prefix) {
                all[key] = try ui.store.daemonState(key, as: JSONValue.self)
            }
            return .object(all)
        }
        guard let key else { throw RPCError.invalidParams("missing key") }
        if Store.trustKeys.contains(key) { return try ui.store.daemonState(key, as: JSONValue.self) ?? .null }
        return try ui.store.uiState(prefix: key)[key] ?? .null
    }
}

extension StateSet: Handled {
    static var inOrder: Bool { true }
    /// Which projects may run their own code in language servers and formatters, and which extensions may run commands:
    /// the user's say, in Kelp's window (as `scripts.trust`); an agent's call or a repository's script can't record it.
    var onlyFromKelp: String? {
        switch key {
        case ExtensionFiles.extensionTrustKey: "Only Kelp's window allows an extension to run commands."
        case Repo.devContainerKey: "Only Kelp's window runs a project in its dev container."
        case Repo.machineKey: "Only Kelp's window runs a project's terminals in a machine."
        case _ where key.hasPrefix("lsp."): "Only Kelp's window can trust a project for language servers."
        default: nil
        }
    }
    func handle(_ ui: UIStore) throws -> Done {
        // The trust is kept apart from the rest (`Store.trustKeys`): only this writes it, from Kelp's window.
        if Store.trustKeys.contains(key) {
            try ui.store.setDaemonState(key, value)
        } else {
            try ui.store.setUIState(key, value)
        }
        return Done()
    }
}

extension ClientEvents: Handled {
    static var inOrder: Bool { true }   // before whatever is broadcast after it
    func handle(_ clients: Clients, conn: Int) throws -> Done {
        clients.setMuted(conn, !events)
        return Done()
    }
}

extension Methods {
    static let uiMethods: [any Answered.Type] = [
        UIPublish.self, UIStateGet.self, UIOpen.self, UICommand.self, UIBrowser.self, UIBrowserReply.self,
        StateGet.self, StateSet.self, ClientEvents.self
    ]
}
