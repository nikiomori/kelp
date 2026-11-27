import Core
import Foundation

/// Agents → app: `kelp open`, `kelp ui` etc. call `ui.*`; the daemon relays them to the app as `event.ui`.
/// The app publishes what it shows (`ui.publish`) so agents can read it back (`ui.state`), and keeps what it restores
/// (each workspace's layout, the sidebar's order…) in the database with `state.*`, so every KELP_HOME has its own.
extension UIPublish: Handled {
    static var inOrder: Bool { true }
    /// Only Kelp's window says what's on screen (and gets event.ui): an agent can't stand in for it.
    var fence: Fence { Fence(onlyFromKelp: "Only Kelp's window publishes its state.") }
    func handle(_ clients: Clients, conn: Int) throws -> Done {
        clients.publishUI(state, from: conn)
        return Done()
    }
}

extension UIStateGet: Handled {
    static let agents = AgentAccess.reads
    func handle(_ clients: Clients) throws -> ShownUI { clients.uiState }
}

extension UIOpen: Handled {
    static let agents = AgentAccess.acts
    /// A terminal or an agent that the app starts belongs to nobody; when an agent asks for one, it comes through `kelp
    /// session new`, which makes it the agent's own.
    /// The scheme is read as the app reads it (`TabURI.scheme`, in any case), not as it is spelled, since `TERMINAL:`
    /// runs a command too.
    private var scheme: String { uri.firstIndex(of: ":").map { uri[..<$0].lowercased() } ?? "file" }
    var fence: Fence { Fence(inWorkspace: workspace, notForAgents: refusal, shows: shown) }
    private var refusal: String? {
        if ["terminal", "agent"].contains(scheme) {
            return "An agent starts terminals and agents with `kelp session new`, which keeps them its own."
        }
        if scheme == "settings" { return "Settings open from Kelp's own controls: `kelp settings set` changes one." }
        if scheme == "agentweb" {
            return "Open your browser page with `kelp browser open <url>`, which assigns its owner."
        }
        // A plain page tab has the user's cookies (and `kelp shot` sees it), while an agent's page has cookies of its
        // own. A local page (`preview:`) has the user's cookies too, and it can go on to any site.
        if ["http", "https", "preview"].contains(scheme) {
            return "A page tab opened this way is logged in as the user: open it with `kelp browser open <url>` "
                + "(a local page: `kelp browser open preview:<path>`), which gives it cookies of its own."
        }
        return nil
    }
    /// A session's tab shows its screen and a subagent's tab its journal; an agent may open either for itself or for a
    /// session it started. (`named(by:)` only sees bare ids, so these are checked here.)
    private var shown: String? {
        guard ["session", "subagent"].contains(scheme) else { return nil }
        return lead
    }
    /// The workspace a tab names, for the fence. A tab that names its workspace in its body (`db:<workspace>/<name>`,
    /// `diff:<workspace>?…`) is opened by the app as the user, so that workspace is checked as if it were the call's
    /// field. Otherwise the workspace is `worktreeId`. When none is named the tab would open in the workspace on
    /// screen, which needn't be the agent's, so the answer is `""`, which the fence refuses (as it does for
    /// `ui.browser`); a session's tab is the exception, since its session decides where it goes. A database tab's
    /// workspace is read the same way the tab reads it (`DatabaseTabURI.parts`, which reads past a `?` or `/` before
    /// the id); which database it may open is the fence's check (`AgentRules.allow`).
    private var workspace: String? {
        if let database = DatabaseTabURI.parts(uri) { return database.worktree }
        let named = shown == nil && UUID(uuidString: lead) != nil ? lead : nil
        return named ?? worktreeId ?? (shown == nil ? "" : nil)
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
    static let agents = AgentAccess.acts
    var fence: Fence {
        guard Self.forAgents.contains(id) else {
            return Fence(
                notForAgents: "“\(id)” is the user's to run: an agent runs only commands that show something, and "
                    + "starts sessions with `kelp session`.")
        }
        return id == "artifacts.export" ? exportFence() : Fence()
    }

    /// An export writes over whatever is at `to`, so an agent exports a page of its own project into that project.
    private func exportFence() -> Fence {
        guard case .object(let a) = args, case .string(let path) = a["path"], case .string(let to) = a["to"],
            let root = path.range(of: "/.kelp/artifacts/").map({ String(path[..<$0.lowerBound]) })
        else { return Fence(notForAgents: "An export names its page and where it goes.") }
        guard Paths.inside(to, root), Paths.realNearest(to) != Paths.realNearest(root) else {
            return Fence(
                notForAgents: "An agent exports into its project's folder (\(root)), never over a file elsewhere.")
        }
        return Fence(writesInFolder: root)
    }
    func handle(_ clients: Clients) throws -> Delivered { try clients.relay(UIEvent(self)) }
}

/// Sends a `kelp browser` command to the app, which runs it in a browser tab and answers with `ui.browser.reply`; this
/// waits for that answer.
extension UIBrowser: AsyncHandled {
    static let agents = AgentAccess.acts
    // With no workspace named, the page would open in the one on screen, which needn't be the agent's.
    var fence: Fence { Fence(inWorkspace: worktreeId ?? "") }
    func handle(_ relay: BrowserRelay, conn: Int) async throws -> JSONValue {
        let asker = relay.asks.clients.connection(conn)?.peerPID
        return try await forward(relay, driver: relay.driver(conn, words: Self.words(action, args)), asker: asker)
    }

    fileprivate func forward(
        _ relay: BrowserRelay, driver: BrowserRelay.Driver, asking: String? = nil, asker: pid_t? = nil
    ) async throws -> JSONValue {
        let ui = relay.ui
        ui.browserUsed(in: worktreeId)   // an agent wants pages here, whether or not the app is there to show one
        let clients = ui.clients, apps = clients.apps
        guard !apps.isEmpty else { throw RPCError.internalError("The Kelp app isn't running") }
        guard case .object(var fields) = args ?? .object([:]) else {
            throw RPCError.invalidParams("kelp browser's args are an object")
        }
        // kelpd supplies the routing fields. A caller can name an address, but cannot claim another page's owner.
        fields["remote"] = HostBrowser.page
        fields["session"] = driver.session.map(JSONValue.string)
        fields["subagent"] = driver.subagent.map(JSONValue.string)
        fields["askingSession"] = asking.map(JSONValue.string)
        fields["yourLogin"] = nil
        if action == .open { fields["yourLogin"] = try await relay.login(fields, driver: driver, asker: asker) }
        var call = self
        call.args = .object(fields)
        let request = UUID().uuidString
        return try await clients.reply(to: request, from: apps, within: Self.wait) {
            clients.notify(UIBrowserEvent(call, request: request), to: apps)
        }
    }

    /// What the command line says after `kelp browser`: `click e12`, `open http://localhost:3000`.
    static func words(_ action: BrowserAction, _ args: JSONValue?) -> String {
        ([action.rawValue] + ["ref", "key", "url"].compactMap { args?[$0]?.string }.prefix(1)).joined(separator: " ")
    }
}

/// Hands the page to the user with the question, and the agent's row asks it, the way Kelp's own questions are asked
/// (`askForKelp`). Done on the page answers Allow. Then the page leaves the question behind, and the reply carries the
/// answer.
extension UIBrowserAsk: AsyncHandled {
    static let agents = AgentAccess.acts
    var fence: Fence { Fence(inWorkspace: worktreeId ?? "") }
    func handle(_ relay: BrowserRelay, conn: Int) async throws -> JSONValue {
        // A user can name the row that asks without changing the owner of the browser page.
        let driver = try relay.driver(conn, words: UIBrowser.words(.ask, args))
        let row = driver.session ?? args?["session"]?.string ?? Caller.session(of: Sessions.asker)
        guard let session = row, let ls = relay.asks.existing(session) else {
            throw RPCError.invalidParams("kelp browser ask runs in a session of Kelp's: its row asks the user.")
        }
        func page(_ fields: [String: JSONValue]) async throws -> JSONValue {
            var all: [String: JSONValue] = [:]
            if case .object(let given) = args { all = given }
            all.merge(fields) { $1 }
            return try await UIBrowser(action: .ask, args: .object(all), worktreeId: worktreeId)
                .forward(relay, driver: driver, asking: session)
        }
        _ = try await page(["text": .string(question)])
        let asked = Self.rowQuestion(question)
        let answer = await relay.asks.permissions.waitForKelp(
            ls, question: asked, within: Self.wait, asker: relay.asks.clients.connection(conn)?.peerPID)
        let ended = answer ?? "none"
        guard case .object(var shown) = try await page(["ended": .string(ended)]) else { return .null }
        shown["answer"] = .string(ended)
        return .object(shown)
    }
}

/// What answers `ui.browser`: the window it goes to, the sessions that say which subagent asks, and the settings that
/// hold the sites where agents use the user's login.
struct BrowserRelay {
    let ui: UIStore, asks: AgentAsks, settings: SettingsEvents
    typealias Driver = (session: String?, subagent: String?)

    fileprivate func driver(_ conn: Int, words: String) throws -> Driver {
        guard let own = asks.store.agent(origin: Sessions.asker) else { return (nil, nil) }
        guard let session = own else { throw RPCError.refused("This browser command needs a Kelp session.") }
        guard HostBrowser.page == nil, let live = asks.existing(session) else { return (session, nil) }
        var call: String?, thread = LiveSession.BrowserThread.unknown
        if live.snapshot.agent == Session.codexAgent, let pid = asks.clients.connection(conn)?.peerPID {
            // Limit: the agent sets its own environment, so a Codex thread could name another thread of its chat. The
            // chat itself comes from the caller's process, and a page with the user's login is the chat's anyway.
            let env = Subprocess.environment(pid, keys: ["CODEX_TOOL_CALL_ID", "CODEX_SESSION_ID", "CODEX_THREAD_ID"])
            call = env["CODEX_TOOL_CALL_ID"].flatMap { $0.isEmpty ? nil : $0 }
            if let label = env["CODEX_THREAD_ID"], let id = UUID(uuidString: label),
                let root = env["CODEX_SESSION_ID"].flatMap(UUID.init(uuidString:))
            {
                thread = id == root ? .root : .child(label)
            }
        }
        return (session, try live.browsing(toolCall: call, thread: thread, words: words))
    }
}

extension UIBrowserReply: Handled {
    var fence: Fence { Fence(onlyFromKelp: "Only Kelp's window answers browser requests.") }
    func handle(_ clients: Clients) throws -> Done {
        clients.answer(request, error.map { .failure(RPCError.internalError($0)) } ?? .success(result ?? .null))
        return Done()
    }
}

extension Clients {
    /// Relays an event to every Kelp window as `event.ui`.
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
    static let agents = AgentAccess.reads
    static var quick: Bool { true }
    func handle(_ ui: UIStore) throws -> JSONValue {
        if let prefix {
            var all = try ui.store.uiState(prefix: prefix)
            // Trust keys come from daemonState, never from a stale copy an older daemon left in uiState (and none comes
            // back where the trust was taken back).
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
    /// Settings that record which projects may run their own code in language servers and formatters, and which
    /// extensions may run commands. Only the user decides these, in Kelp's window (as with `scripts.trust`); neither an
    /// agent's call nor a repository's script can record them.
    var fence: Fence { Fence(onlyFromKelp: trustedBy) }
    private var trustedBy: String? {
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
    static let agents = AgentAccess.reads
    static var inOrder: Bool { true }   // before whatever is broadcast after it
    func handle(_ clients: Clients, conn: Int) throws -> Done {
        clients.setMuted(conn, !events)
        return Done()
    }
}

extension Methods {
    static let uiMethods: [any Answered.Type] = [
        UIPublish.self, UIStateGet.self, UIOpen.self, UICommand.self, UIBrowser.self, UIBrowserAsk.self,
        UIBrowserReply.self,
        StateGet.self, StateSet.self, ClientEvents.self
    ]
}
