import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// Kelp's side of a server: its agents there (and what each costs), what still runs in Kelp's tmux sessions though no tab
/// shows it, its Docker containers, the ports something listens on and what does (forwarded here in a click), and its
/// projects.
struct ServerSide: View {
    let app: AppModel, host: String, stats: HostStats
    /// Port on the host → port on this Mac, once forwarded (this run of Kelp).
    private var forwarded: [Int: Int] { app.part { ServerForwards() }.ports[host] ?? [:] }

    private var projects: [Repo] { app.repos.filter { RemoteHost.of($0.path)?.host == host } }
    private var screens: Set<String> {
        let ids = Set(projects.map(\.id))
        return Set(app.worktrees.filter { ids.contains($0.repoId) }.map(\.id))
    }
    private var agents: [Session] {
        app.sessions.filter { screens.contains($0.worktreeId ?? "") && $0.status != .exited && $0.isChat }
    }
    /// Kelp's tmux sessions no live tab shows: closed here, or dropped with the connection, still running there.
    private var leftRunning: [HostStats.TmuxSession] {
        (stats.tmux ?? []).filter { t in t.session.flatMap(app.session).map { $0.status == .exited } ?? true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agents").sectionHeading()
            if agents.isEmpty { Text("No agents on \(host) now.").quietNote() }
            ForEach(agents, id: \.id) { s in agentRow(s) }
            if !leftRunning.isEmpty {
                Text("Still Running in tmux").sectionHeading().padding(.top, Metrics.gapWide)
                ForEach(leftRunning, id: \.name) { t in tmuxRow(t) }
            }
            if let containers = stats.containers, !containers.isEmpty {
                HStack(spacing: Metrics.gap) {
                    Text("Containers").sectionTitle()
                    Text(verbatim: "\(containers.count)").font(.ui(TextSize.caption)).foregroundStyle(.tertiary)
                }
                .frame(height: Metrics.rowSection, alignment: .bottom).padding(.top, Metrics.gapWide)
                ForEach(containers, id: \.name) { c in containerRow(c) }
            }
            if let ports = stats.ports, !ports.isEmpty {
                Text("Listening").sectionHeading().padding(.top, Metrics.gapWide)
                ForEach(ports, id: \.port) { p in
                    PortRow(
                        port: p, forwardedTo: forwarded[p.port], open: { open(port: $0) }, forward: { forward(p.port) })
                }
            }
            Text("Projects").sectionHeading().padding(.top, Metrics.gapWide)
            ForEach(projects, id: \.id) { r in projectRow(r) }
        }
    }

    /// What its processes there take together.
    private func cost(_ sid: String) -> String? {
        let mine = (stats.processes ?? []).filter { $0.session == sid }
        guard !mine.isEmpty else { return nil }
        let cpu = mine.reduce(0) { $0 + $1.cpu }, memory = mine.reduce(0) { $0 + $1.memory }
        return String(format: "%.1f%%", cpu) + " · " + bytes(memory)
    }

    private func agentRow(_ session: Session) -> some View {
        Button {
            app.workbench.focus(session: session.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    StatusIcon(status: session.markStatus, waitsForCommand: session.waitsForCommand)
                    Text(app.catalog.displayName(session)).font(.ui(TextSize.row)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let usage = cost(session.id) {
                        Text(usage).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if session.status == .waiting, !session.summary.isEmpty {
                    (Text("Asks: ").foregroundColor(Color(nsColor: .textOrange))
                        + Text(session.summary).foregroundColor(.secondary))
                        .font(.ui(TextSize.caption)).lineLimit(1).padding(.leading, 18)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle())
    }

    private func tmuxRow(_ tmux: HostStats.TmuxSession) -> some View {
        let session = tmux.session.flatMap(app.session)
        return HStack(spacing: 6) {
            Image(systemName: "moon").font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.map(app.catalog.displayName) ?? tmux.name).font(.ui(TextSize.row)).lineLimit(1)
                Text(
                    session == nil
                        ? String(localized: "Not started by this Kelp · \(tmux.name)")
                        : String(localized: "Closed in Kelp, still running")
                )
                .font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let session {
                Button(String(localized: "Open")) { app.workbench.focus(session: session.id) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 6).frame(minHeight: Metrics.rowTwoLine)
    }

    /// A container: its name, how long it's been up and the ports it's published on, and what it takes. Its log a right
    /// click away.
    private func containerRow(_ container: HostStats.Container) -> some View {
        let line = [
            container.seconds.map { String(localized: "up \(shortSpan(Double($0), units: 2))") },
            container.ports.isEmpty ? nil : container.ports.map(String.init).joined(separator: ", ")
        ].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 6) {
            Image(systemName: "shippingbox").font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary).frame(
                width: 14)
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(container.name).font(.ui(TextSize.row)).lineLimit(1)
                if !line.isEmpty {
                    Text(line).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let memory = container.memory {
                Text(bytes(memory)).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6).frame(minHeight: Metrics.rowTwoLine)
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "Show Log")) {
                ServerActions.runOnServer(
                    app, host, command: "docker logs -f --tail 200 \(ShellQuote.word(container.name))",
                    title: container.name)
            }
            Button(String(localized: "Copy Name")) { copyText(container.name) }
        }
    }

    private func open(port here: Int) {
        if let wid = ServerActions.serverWorkspace(app, host) {
            app.workbench.open("http://localhost:\(here)", workspace: wid)
        }
    }

    private func projectRow(_ repo: Repo) -> some View {
        Button {
            if let workspace = mainWorkspace(of: repo, among: app.worktrees) {
                app.workbench.show(workspace: workspace.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary).frame(
                    width: 14)
                Text(repo.name).font(.ui(TextSize.row))
                Spacer(minLength: 6)
                Text(RemoteHost.of(repo.path)?.path ?? "").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 6).frame(height: Metrics.row).contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle())
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

/// A port something listens on: what does (its container, or its program when ss says), and where it's reached. Forward
/// stays on a port the server keeps to itself, the only way to reach it from here; on one open to all it comes under
/// the pointer; never on ssh's own. Once forwarded, the port here, opened in a click.
private struct PortRow: View {
    let port: HostStats.Port, forwardedTo: Int?
    let open: (Int) -> Void, forward: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(port.port)").font(.ui(TextSize.row).monospacedDigit()).frame(
                width: 40, alignment: .leading)
            if let container = port.container {
                Image(systemName: "shippingbox").font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary)
                Text(container).font(.ui(TextSize.row)).lineLimit(1).truncationMode(.middle)
            } else if let process = port.process {
                Text(process).font(.ui(TextSize.row)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let here = forwardedTo {
                Button("localhost:\(here)") { open(here) }
                    .buttonStyle(PointerButtonStyle()).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(
                        Color.accentColor
                    )
                    .help(String(localized: "Open in the browser beside you"))
            } else if port.port != 22, port.local || hovering {
                Button(String(localized: "Forward")) { forward() }.controlSize(.small)
                    .help(String(localized: "Reach it from this Mac as localhost"))
            } else {
                Text(port.local ? String(localized: "this server only") : String(localized: "all addresses"))
                    .font(.ui(TextSize.caption)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).frame(height: Metrics.row)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(hovering ? Color(nsColor: .fillHover) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(
            port.local ? String(localized: "Only this server reaches it") : String(localized: "Open on all addresses"))
    }
}
