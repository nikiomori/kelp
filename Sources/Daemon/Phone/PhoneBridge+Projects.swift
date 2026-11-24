import AgentData
import Agents
import Core
import Foundation

// This file holds what a phone sees beside the agents, and what it may start. That is the Mac's projects in the
// sidebar's order, their icons, the agents that run on this Mac, and an agent's conversation. A phone could already
// tell a running agent anything. Starting an agent is kept to the projects and agents listed here, and it is called
// as the user's own call, like Allow.

extension PhoneBridge {
    /// An agent that a phone may start, because its program is on this Mac.
    struct Kind: Equatable, Sendable {
        var id: String, name: String
        /// Whether new chats start with this agent (`agents.default`). The page's sheet opens with it chosen.
        var isDefault = false
    }

    /// Runs work that reads a disk or asks the login shell off the bridge's own thread. Returns nil once the daemon
    /// stops taking work.
    private func offloaded<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value? {
        do { return try await offloads.run(work) } catch { return nil }
    }

    /// Returns the projects as the sidebar lists them, by name unless the user dragged them into another order
    /// (`sidebar.order`). It leaves out the chats that have no project, because each of those gets a folder of its
    /// own, made in Kelp's window.
    func projects() -> [Repo] {
        let repos = Log.session.attempt("reading the projects") { try store.repos() } ?? []
        let scratch = Paths.real(root.appendingPathComponent("scratch").path)
        return inSidebarOrder(repos.filter { scratch == nil || Paths.real($0.path) != scratch })
    }

    /// Returns a project's first workspace that is not archived, in the sidebar's order. An agent started from the
    /// phone begins there.
    func firstWorkspace(of repo: Repo) -> Worktree? {
        let all = Log.session.attempt("reading the workspaces") { try store.worktrees(repo: repo.id) } ?? []
        return inSidebarOrder(all.filter { !$0.archived }).first
    }

    private func inSidebarOrder<Row: Identifiable>(_ rows: [Row]) -> [Row] where Row.ID == String {
        let kept = Log.session.attempt("reading the sidebar's order") {
            try store.uiState(prefix: StateKeys.sidebarOrder)
        }
        let order = kept?[StateKeys.sidebarOrder]?.array?.compactMap(\.string) ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return rows.enumerated().sorted { (rank[$0.1.id] ?? .max, $0.0) < (rank[$1.1.id] ?? .max, $1.0) }.map(\.1)
    }

    /// Returns the agents a phone may start. The list is empty while Settings › Phone keeps starting agents off, so
    /// the page offers no "+" and a start is refused.
    /// Limit: an agent counts when its command is on the login shell's PATH, with no check that it runs, so a shim
    /// whose program is gone counts.
    func kinds() async -> [Kind] {
        guard settings[SettingKeys.phoneStartAgents] else { return [] }
        let agents = Paths.agents(in: root), usual = settings[SettingKeys.defaultAgent]
        let found = await offloaded {
            AgentManifest.load(dir: agents).filter { Session.isAgent($0.id) && LoginPath.find($0.command) != nil }
                .map { Kind(id: $0.id, name: $0.name, isDefault: $0.id == usual) }
        }
        return found ?? []
    }

    /// Returns the `projects` and `kinds` fields of the agents list.
    func projectsAndKinds() async -> [String: JSONValue] {
        let projects = projects(), kinds = await kinds()
        await findIcons(projects)
        return [
            "projects": .array(
                projects.map {
                    .object([
                        "id": .string($0.id), "name": .string($0.name),
                        "icon": .bool(iconFiles[$0.path]?.file != nil)
                    ])
                }),
            "kinds": .array(
                kinds.map { kind in
                    var fields: [String: JSONValue] = ["id": .string(kind.id), "name": .string(kind.name)]
                    if kind.isDefault { fields["default"] = .bool(true) }
                    return .object(fields)
                })
        ]
    }

    /// Finds each project's icon file where the sidebar finds it (`IconSearch`, or for a remote project the copy kept
    /// in its folder on this Mac). It looks again after five minutes. Limit: an SVG can't be used here, since nothing
    /// in kelpd draws it.
    private func findIcons(_ projects: [Repo]) async {
        let now = Date()
        let stale = projects.map(\.path).filter { now.timeIntervalSince(iconFiles[$0]?.found ?? .distantPast) > 300 }
        guard !stale.isEmpty else { return }
        let found = await offloaded {
            stale.map { path -> (String, String?) in
                let kept = FileManager.default.names(in: path + "/.kelp-icon").first.map { path + "/.kelp-icon/" + $0 }
                let file = kept ?? IconSearch.find(in: path)
                return (path, file.flatMap { $0.lowercased().hasSuffix(".svg") ? nil : $0 })
            }
        }
        for (path, file) in found ?? [] { iconFiles[path] = (file, now) }
    }

    /// Answers the paths `projects/<id>/icon` and `projects/<id>/agents`.
    func answer(_ method: String, project id: String, _ what: String, _ sent: JSONValue?) async -> Reply {
        guard let repo = projects().first(where: { $0.id == id }) else { return .failed(404, "No such project.") }
        switch (method, what) {
        case ("GET", "icon"):
            await findIcons([repo])
            let png = await offloaded { [file = iconFiles[repo.path]?.file] in
                file.flatMap { FileManager.default.contents(atPath: $0) }.flatMap { PhoneIcon.png(from: $0) }
            }
            guard let png = png ?? nil else { return .failed(404, "It has no icon.") }
            return Reply(
                status: 200,
                body: .object(["type": .string("image/png"), "data": .string(png.base64EncodedString())]))
        case ("POST", "agents"):
            guard settings[SettingKeys.phoneStartAgents] else {
                return .failed(403, "Starting agents from a phone is turned off in Kelp's Settings.")
            }
            let prompt = sent?["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let kind = sent?["agent"]?.string, !prompt.isEmpty, await kinds().contains(where: { $0.id == kind })
            else { return .failed(400, "Send {\"agent\", \"prompt\"}.") }
            guard let workspace = firstWorkspace(of: repo) else {
                return .failed(409, "This project has no workspace.")
            }
            do {
                let started = try await call(SessionCreate(worktreeId: workspace.id, agent: kind, prompt: prompt))
                return Reply(status: 200, body: .object(["id": .string(started.id)]))
            } catch { return .failed(403, error.rpcMessage) }
        default: return .failed(404, "No such path.")
        }
    }

    /// The conversation fields of GET agents/<id>. The relay passes at most a megabyte.
    func conversationFields(of session: Session) async -> [String: JSONValue] {
        let conversations = conversations, running = live[session.id]
        guard let detail = await offloaded({ conversations.phoneConversation(of: session, live: running) }) else {
            return ["lastReply": .null]
        }
        let reply = detail.reply.map { JSONValue.string(String($0.suffix(200_000))) }
        var fields: [String: JSONValue] = ["lastReply": reply ?? .null]
        guard !detail.turns.isEmpty else { return fields }
        fields["turns"] = .array(detail.turns.map { turn in
            var fields: [String: JSONValue] = ["role": .string(turn.role.rawValue), "text": .string(turn.text)]
            if let at = turn.at { fields["at"] = .string(at) }
            return .object(fields)
        })
        return fields
    }
}
