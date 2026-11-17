import Agents
import AppKit
import Core
import DesignKit
import Foundation
import Observation

/// The agents the UI offers, which are the ones that actually run on this Mac (see AgentAvailability). The app reaches
/// it as `app.catalog`.
@MainActor
package struct AgentCatalog {
    let app: AppModel
    /// The agents (and the terminal) this Mac has.
    package var installed: [AgentManifest] {
        let ok = app.availability.ids
        return all.filter { ok.contains($0.id) }
    }

    /// Returns the agents a new tab in `worktree` can start. For a remote project these are the agents its host has
    /// (once the host has answered, and this call asks it), otherwise this Mac's. A terminal is always among them.
    func startable(in worktree: Worktree?) -> [AgentManifest] {
        guard let worktree, let host = RemoteHost.of(worktree.path)?.host else { return installed }
        app.availability.refreshHost(host, workspace: worktree.id, commands: all.map(\.command))
        guard let there = app.availability.onHost[host] else { return installed }
        return all.filter {
            !Session.isAgent($0.id) || there.contains(($0.command as NSString).lastPathComponent)
        }
    }

    /// Built-in and user agent manifests plus agents contributed by extensions.
    package var all: [AgentManifest] {
        let base = app.agents
        return base + app.extensions.all.agents.filter { a in !base.contains { $0.id == a.id } }
    }
    /// The agent that "New Agent" starts: the one in the setting if it's installed, else the first installed one.
    package var defaultAgent: String {
        let installed = self.installed
        let agentId = app.settings[SettingKeys.defaultAgent]
        if installed.contains(where: { $0.id == agentId }) { return agentId }
        return installed.first?.id ?? SettingKeys.defaultAgent.fallback
    }
    /// Whether to offer tmux sessions in a workspace. That is when tmux is on this Mac, or the project is on a host,
    /// which usually has tmux (tmux.list says so when it doesn't).
    func hasTmux(_ worktree: Worktree?) -> Bool {
        app.availability.ids.contains("tmux") || worktree.flatMap { RemoteHost.of($0.path) } != nil
    }
    /// The default agent, nil while no agent CLI is found (nothing to start).
    var startable: String? { installed.isEmpty ? nil : defaultAgent }
    package func name(_ id: String?) -> String {
        guard let id else { return "Terminal" }
        if id == Session.shellAgent { return String(localized: "Terminal") }
        return all.first { $0.id == id }?.name ?? id.capitalized
    }

    /// Returns the session's title, or else the agent's name, numbered when the same agent runs twice in one workspace.
    /// Sidebar, tabs, notifications and menus all use this, so they agree.
    package func displayName(_ session: Session) -> String {
        if !session.title.isEmpty { return session.title }
        let base = name(session.agent)
        // The number comes from an index, because every row and tab asks on every session event.
        guard let number = app.untitledNumber(session.id) else { return base }
        return "\(base) \(number)"
    }

    /// Agent `id`'s own colour (`#rrggbb`), if its manifest has one.
    package func color(_ id: String?) -> String? { manifest(id)?.color }
    /// The manifest of agent `id`, whether it is a preset, a file or an extension's.
    func manifest(_ id: String?) -> AgentManifest? { id.flatMap { id in all.first { $0.id == id } } }
    /// Says what an agent is in a few words, shown beside its name in the empty workspace and Settings › Agents.
    package func about(_ id: String) -> String? { manifest(id)?.about.map(loc) }
    /// The agents the empty workspace offers to install when no agent is on this Mac. The rest are in Settings ›
    /// Agent Catalog.
    var suggested: [AgentManifest] {
        all.filter { $0.featured != nil && $0.install != nil }.sorted { ($0.featured ?? 0) < ($1.featured ?? 0) }
    }
    /// Runs the agent's own install command in a terminal tab of `e`, in plain sight. Once it ends, the agent is looked
    /// for again. When the installer needs npm or Homebrew and the Mac lacks it, a banner says so instead of the
    /// installer failing in its tab.
    package func install(_ agentManifest: AgentManifest, in e: SessionStarter) {
        guard let cmd = agentManifest.install else { return }
        Task { [app] in
            if let tool = agentManifest.installNeeds, let found = await app.quiet(ProcessWhich(commands: [tool])),
                found[tool] == nil
            {
                let first =
                    tool == "npm"
                    ? String(localized: "Install Node.js first (nodejs.org, or brew install node).")
                    : String(localized: "Install Homebrew first (brew.sh).")
                Banner.show(
                    String(localized: "\(agentManifest.name) installs with \(tool), which isn’t on this Mac. ") + first,
                    style: .error)
                return
            }
            e.run(command: cmd, title: String(localized: "Install \(agentManifest.name)")) { session in
                app.availability.watchInstall(session.id, agent: agentManifest.id)
            }
        }
    }

    /// The agent's real icon when there is one (AgentIcons), else its initial on a tile of the same shape; for a
    /// terminal, a terminal symbol. It returns the same image object each time, because a tab's look is compared with
    /// its last look on every change of every session, and a new image never equals the last one. `agentIcons` is still
    /// read, so whoever shows the icon hears when the real icon arrives.
    package func icon(_ id: String?, size: CGFloat = 16) -> NSImage? {
        guard let id, Session.isAgent(id) else {
            let name = id == Session.customAgent ? "apple.terminal" : "terminal"
            if let known = app.agentIcons.made[name] { return known.image }
            let image = NSImage.symbol(name)
            app.agentIcons.made[name] = (nil, image)
            return image
        }
        let agent = manifest(id)
        let real = app.agentIcons.image(id, apps: agent?.apps ?? [], site: agent?.site)
        let title = name(id), key = "\(id) \(size) \(title)"
        if let known = app.agentIcons.made[key], known.source === real { return known.image }
        let image: NSImage
        if let copy = real?.copy() as? NSImage {
            copy.size = NSSize(width: size, height: size)
            image = copy
        } else {
            image = IconTile.letter(title, color: agent?.color.flatMap(NSColor.init(hex:)), size: size)
        }
        app.agentIcons.made[key] = (real, image)
        return image
    }
}

/// Which agent CLIs run on this Mac. An agent counts when it is on the login shell's PATH and answers `--version`, so a
/// shim whose binary is gone (a broken npm install) doesn't count. It is checked in the background at launch and when
/// Kelp comes back to the front (at most every few minutes), so newly installed agents show up. The last answer is
/// remembered for the next launch.
@MainActor
@Observable
package final class AgentAvailability {
    @ObservationIgnored let app: AppModel
    init(app: AppModel) { self.app = app }
    private(set) package var ids = Set(UserDefaults.standard.stringArray(forKey: "agents.available") ?? [])
    /// The agent commands each remote host has (`HostCommands`), by host. A host is asked again after five minutes.
    private(set) var onHost: [String: Set<String>] = [:]
    @ObservationIgnored private var hostAsked: [String: Date] = [:]

    func refreshHost(_ host: String, workspace: String, commands: [String]) {
        guard Date().timeIntervalSince(hostAsked[host] ?? .distantPast) > 300 else { return }
        hostAsked[host] = Date()
        Task {
            guard let found = await app.quiet(HostCommands(worktreeId: workspace, commands: commands)) else {
                hostAsked[host] = nil   // the host wasn't reached, so ask again next time
                return
            }
            onHost[host] = Set(found)
        }
    }
    @ObservationIgnored private var checkedAt = Date.distantPast
    @ObservationIgnored private var checking = false
    /// A forced check asked for while another check runs. It runs once that one is done, so the end of an installer
    /// isn't missed.
    @ObservationIgnored private var queued: (rereadPath: Bool, expecting: Set<String>)?

    /// The phase of an installer started from Kelp, kept per agent. It is running in its tab, ended without the agent
    /// found, or ended with it found.
    package enum InstallPhase: Equatable { case running(tab: String), notFound(tab: String), done }
    private(set) package var phases: [String: InstallPhase] = [:]

    /// Records that `agent`'s installer runs in session `tab`. When it ends, the agents are looked for again at once,
    /// without waiting for the next check.
    func watchInstall(_ tab: String, agent: String) { phases[agent] = .running(tab: tab) }
    func sessionChanged(_ session: Session) {
        guard session.status == .exited, let agent = phases.first(where: { $0.value == .running(tab: session.id) })?.key
        else {
            return
        }
        refresh(force: true, rereadPath: true, expecting: [agent])
    }

    /// Checks which agents run. Pass `rereadPath` when an installer just ran, so the daemon first reads the login
    /// shell's PATH again and finds the folder the installer added to the profile. `expecting` lists agents whose
    /// installer ended, and one that still isn't found becomes `.notFound`.
    package func refresh(force: Bool = false, rereadPath: Bool = false, expecting: Set<String> = []) {
        let app = self.app
        guard !checking else {
            if force { queued = (rereadPath || queued?.rereadPath == true, expecting.union(queued?.expecting ?? [])) }
            return
        }
        guard force || Date().timeIntervalSince(checkedAt) > 300 else { return }
        checking = true
        let commands = app.catalog.all.filter { $0.id != Session.customAgent }.map { ($0.id, $0.command) }
        let ran = UserDefaults.standard.dictionary(forKey: "agents.ran") as? [String: Double] ?? [:]
        Task.detached(priority: .utility) {
            // The daemon runs the `--version` checks, so without it every agent would look missing. Without a
            // connection nothing is learned, and the next check asks again.
            await app.waitForConnection()
            guard await MainActor.run(body: { app.connected }) else {
                await self.finish(nil, expecting: expecting)
                return
            }
            if rereadPath { _ = await app.quiet(ProcessRefreshPath(), timeout: 20) }   // asking the shell takes ≤ 8 s
            // Ask where the daemon finds the commands on its login-shell PATH ("tmux" too). If that fails, nothing
            // changes.
            guard let paths = await app.quiet(ProcessWhich(commands: commands.map(\.1) + ["tmux"])) else {
                await self.finish(nil, expecting: expecting)
                return
            }
            let found = await withTaskGroup(of: (id: String, binary: String)?.self) { group in
                for (id, command) in commands {
                    if let path = paths[command] {
                        group.addTask { await Self.runs(path, ran: ran, app: app).map { (id, $0) } }
                    }
                }
                var all: [(id: String, binary: String)] = []
                for await result in group { if let result { all.append(result) } }
                return all
            }
            // tmux isn't an agent. "tmux" among the ids says there's a tmux here to attach to (AgentCatalog.hasTmux).
            let tmux = paths["tmux"] != nil
            let ok = Set(found.map(\.id) + (tmux ? ["tmux"] : [])), now = Date().timeIntervalSince1970
            let keep = Dictionary(found.map { ($0.binary, ran[$0.binary] ?? now) }) { a, _ in a }
            await self.finish(ok, expecting: expecting, ran: keep)
        }
    }

    /// Ends a check. `ok` holds the agents found, or nil when that isn't known. Agents whose installer ran become
    /// `.done` when found, and those expected but not found become `.notFound`.
    private func finish(_ ok: Set<String>?, expecting: Set<String>, ran: [String: Double] = [:]) {
        checking = false
        if let ok {
            checkedAt = Date()
            if ok != ids {
                ids = ok
                UserDefaults.standard.set(Array(ok).sorted(), forKey: "agents.available")
            }
            UserDefaults.standard.set(ran, forKey: "agents.ran")
            for (id, p) in phases where ok.contains(id) && p != .done { phases[id] = .done }
        }
        for id in expecting { if case .running(let tab)? = phases[id] { phases[id] = .notFound(tab: tab) } }
        if let next = queued {
            queued = nil
            refresh(force: true, rereadPath: next.rereadPath, expecting: next.expecting)
        }
    }

    /// Runs `<path> --version`. If it exits 0 within a few seconds, returns the binary (its real path and modification
    /// time), else nil. A binary that ran in the last day (`ran`: binary → when) and hasn't changed isn't started
    /// again, because starting a dozen agent CLIs at every launch costs seconds of CPU (one took 2 s). Waits without
    /// holding a thread, since they're all asked at once.
    nonisolated static func runs(_ path: String, ran: [String: Double] = [:], app: AppModel) async -> String? {
        guard let real = Paths.real(path),
            let mtime = (try? FileManager.default.attributesOfItem(atPath: real)[.modificationDate] as? Date)?
                .timeIntervalSince1970
        else { return nil }
        let binary = "\(real)|\(mtime)"
        if let at = ran[binary], Date().timeIntervalSince1970 - at < 86400 { return binary }
        return await Shell.exec(app, [path, "--version"], timeout: 8).code == 0 ? binary : nil   // a hung one is killed
    }
}

/// What a subagent is called where agents are listed (on a card, or in the dots on a row).
extension Subagent {
    /// The subagent's task, or else its kind, or else just "Subagent".
    package var title: String { task ?? (kind.isEmpty ? String(localized: "Subagent") : kind) }
    /// The kind shown beside the task. It is nil for general-purpose, because nine in ten subagents are that kind and
    /// it tells them apart from nothing.
    var shownKind: String? { task == nil || kind.isEmpty || kind == "general-purpose" ? nil : kind }
}
