import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// Kelp's side of a server: its agents there (and what each costs), what still runs in Kelp's tmux sessions though no
/// tab shows it, its Docker containers, the ports something listens on and what listens (forwarded here in a click),
/// and its projects.
struct ServerSide: View {
    let app: AppModel, host: String, stats: HostStats
    /// The port on this Mac for each port on the host, once forwarded during this run of Kelp.
    private var forwarded: [Int: Int] { app.part { ServerForwards() }.ports[host] ?? [:] }

    private var projects: [Repo] { app.repos.filter { RemoteHost.of($0.path)?.host == host } }
    private var screens: Set<String> {
        let ids = Set(projects.map(\.id))
        return Set(app.worktrees.filter { ids.contains($0.repoId) }.map(\.id))
    }
    private var agents: [Session] {
        app.sessions.filter { screens.contains($0.worktreeId ?? "") && $0.status != .exited && $0.isChat }
    }
    /// Kelp's tmux sessions that no live tab shows: closed here, or dropped with the connection, but still running
    /// there.
    private var leftRunning: [HostStats.TmuxSession] {
        (stats.tmux ?? []).filter { t in t.session.flatMap(app.session).map { $0.status == .exited } ?? true }
    }

    var body: some View { SectionList(sections) }

    /// The column's lists, each under its title: a list with nothing in it is left out, but for the agents (whose
    /// absence is worth saying) and the projects.
    private var sections: [SectionList.Section] {
        var all = [
            SectionList.Section(
                id: "agents", title: String(localized: "Agents"), rows: agents.map(agentRow),
                note: String(localized: "No agents on \(host) now."))
        ]
        if !leftRunning.isEmpty {
            all.append(
                .init(id: "tmux", title: String(localized: "Still Running in tmux"), rows: leftRunning.map(tmuxRow)))
        }
        if let containers = stats.containers, !containers.isEmpty {
            all.append(
                .init(id: "containers", title: String(localized: "Containers"), rows: containers.map(containerRow)))
        }
        if let ports = stats.ports, !ports.isEmpty {
            all.append(.init(id: "ports", title: String(localized: "Listening"), rows: ports.map(portRow)))
        }
        all.append(.init(id: "projects", title: String(localized: "Projects"), rows: projects.map(projectRow)))
        return all
    }

    /// What a session's processes on the server take together.
    private func cost(_ sid: String) -> String? {
        let mine = (stats.processes ?? []).filter { $0.session == sid }
        guard !mine.isEmpty else { return nil }
        let cpu = mine.reduce(0) { $0 + $1.cpu }, memory = mine.reduce(0) { $0 + $1.memory }
        return String(format: "%.1f%%", cpu) + " · " + bytes(memory)
    }

    private func agentRow(_ session: Session) -> SectionList.Row {
        let app = app
        var row = SectionList.Row(id: "agent " + session.id, title: app.catalog.displayName(session))
        row.icon = { NSHostingView(rootView: StatusIcon(status: session.markStatus, of: session)) }
        // The mark's own state: it moves while the row's words stay.
        row.iconKey = [
            "\(session.markStatus)", "\(session.limitHit != nil)", "\(session.compacting)",
            "\(session.waitsForCommand)", "\(session.guessed == true)", "\(session.progress ?? -1)"
        ].joined(separator: " ")
        row.trailing = cost(session.id)
        if session.status == .waiting, !session.summary.isEmpty {
            row.lead = String(localized: "Asks:")
            row.detail = session.summary
        }
        row.click = { app.workbench.focus(session: session.id) }
        return row
    }

    private func tmuxRow(_ tmux: HostStats.TmuxSession) -> SectionList.Row {
        let app = app, session = tmux.session.flatMap(app.session)
        var row = SectionList.Row(id: "tmux " + tmux.name, title: session.map(app.catalog.displayName) ?? tmux.name)
        row.icon = SectionList.symbol("moon")
        row.detail =
            session == nil
            ? String(localized: "Not started by this Kelp · \(tmux.name)")
            : String(localized: "Closed in Kelp, still running")
        if let session {
            row.button = .init(String(localized: "Open")) { app.workbench.focus(session: session.id) }
            row.open = row.button?.run
        }
        return row
    }

    /// A container's row: its name, how long it has been up, the ports it publishes, and what it takes. Its log is a
    /// right-click away, or Return.
    private func containerRow(_ container: HostStats.Container) -> SectionList.Row {
        let app = app, host = host
        let line = [
            container.seconds.map { String(localized: "up \(shortSpan(Double($0), units: 2))") },
            container.ports.isEmpty ? nil : container.ports.map(String.init).joined(separator: ", ")
        ].compactMap { $0 }.joined(separator: " · ")
        var row = SectionList.Row(id: "container " + container.name, title: container.name)
        row.icon = SectionList.symbol("shippingbox")
        row.detail = line.isEmpty ? nil : line
        row.trailing = container.memory.map { bytes($0) }
        let log = SectionList.Action(String(localized: "Show Log")) {
            ServerActions.runOnServer(
                app, host, command: "docker logs -f --tail 200 \(ShellQuote.word(container.name))",
                title: container.name)
        }
        row.menu = [log, .init(String(localized: "Copy Name")) { copyText(container.name) }]
        row.open = log.run
        return row
    }

    /// A port something listens on: what listens (its container, or its program when ss says), and where it's
    /// reached. Forward stays shown on a port the server keeps to itself, because that is the only way to reach it
    /// from here. On a port open to all, Forward shows under the pointer, and it never shows on ssh's own port. Once
    /// the port is forwarded, the row shows the port here, which opens in a click.
    private func portRow(_ port: HostStats.Port) -> SectionList.Row {
        var row = SectionList.Row(id: "port \(port.port)", title: port.container ?? port.process ?? "")
        row.key = "\(port.port)"
        if port.container != nil { row.icon = SectionList.symbol("shippingbox") }
        row.tip =
            port.local ? String(localized: "Only this server reaches it") : String(localized: "Open on all addresses")
        if let here = forwarded[port.port] {
            row.link = .init("localhost:\(here)", tip: String(localized: "Open in the browser beside you")) {
                open(port: here)
            }
            row.open = row.link?.run
            return row
        }
        if !port.local || port.port == 22 {
            row.trailing = port.local ? String(localized: "this server only") : String(localized: "all addresses")
        }
        if port.port != 22 {
            row.button = .init(
                String(localized: "Forward"), tip: String(localized: "Reach it from this Mac as localhost")
            ) {
                forward(port.port)
            }
            row.onHover = !port.local
            row.open = row.button?.run
        }
        return row
    }

    private func open(port here: Int) {
        if let wid = ServerActions.serverWorkspace(app, host) {
            app.workbench.open("http://localhost:\(here)", workspace: wid)
        }
    }

    private func projectRow(_ repo: Repo) -> SectionList.Row {
        let app = app
        var row = SectionList.Row(id: "project " + repo.id, title: repo.name)
        row.icon = SectionList.symbol("folder")
        row.trailing = RemoteHost.of(repo.path)?.path
        row.click = {
            if let workspace = mainWorkspace(of: repo, among: app.worktrees) {
                app.workbench.show(workspace: workspace.id)
            }
        }
        return row
    }

    private func forward(_ port: Int) {
        guard let wid = ServerActions.serverWorkspace(app, host) else { return }
        let app = app, host = host
        Task {
            if let here = await PageActions(app).forward(port, in: wid) {
                app.part { ServerForwards() }.ports[host, default: [:]][port] = here
            }
        }
    }
}
