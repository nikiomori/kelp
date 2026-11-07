import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// Kelp's side of a server: its agents there (and what each costs), what still runs in Kelp's tmux sessions though no tab
/// shows it, the ports something listens on (forwarded here in a click), and its projects.
struct ServerSide: View {
    let app: AppModel, host: String, stats: HostStats
    /// Port on the host → port on this Mac, once forwarded.
    @State private var forwarded: [Int: Int] = [:]

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
            heading("Agents")
            if agents.isEmpty { quiet("No agents on \(host) now.") }
            ForEach(agents, id: \.id) { s in agentRow(s) }
            if !leftRunning.isEmpty {
                heading("Still Running in tmux").padding(.top, 10)
                ForEach(leftRunning, id: \.name) { t in tmuxRow(t) }
            }
            if let ports = stats.ports, !ports.isEmpty {
                heading("Listening").padding(.top, 10)
                ForEach(ports, id: \.port) { p in portRow(p) }
            }
            heading("Projects").padding(.top, 10)
            ForEach(projects, id: \.id) { r in projectRow(r) }
        }
    }

    private func heading(_ text: LocalizedStringKey) -> some View {
        Text(text).sectionTitle().frame(height: Metrics.rowSection, alignment: .bottom)
    }
    private func quiet(_ text: LocalizedStringKey) -> some View { Text(text).font(.ui(12)).foregroundStyle(.secondary) }

    /// What its processes there take together.
    private func cost(_ sid: String) -> String? {
        let mine = (stats.processes ?? []).filter { $0.session == sid }
        guard !mine.isEmpty else { return nil }
        let cpu = mine.reduce(0) { $0 + $1.cpu }, memory = mine.reduce(0) { $0 + $1.memory }
        return String(format: "%.1f%%", cpu) + " · " + serverBytes(memory)
    }

    private func agentRow(_ session: Session) -> some View {
        Button {
            app.workbench.focus(session: session.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    StatusIcon(status: session.markStatus, waitsForCommand: session.waitsForCommand)
                    Text(app.catalog.displayName(session)).font(.ui(12)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let usage = cost(session.id) {
                        Text(usage).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if session.status == .waiting, !session.summary.isEmpty {
                    (Text("Asks: ").foregroundColor(Color(nsColor: .textOrange))
                        + Text(session.summary).foregroundColor(.secondary))
                        .font(.ui(11)).lineLimit(1).padding(.leading, 18)
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
                Text(session.map(app.catalog.displayName) ?? tmux.name).font(.ui(12)).lineLimit(1)
                Text(
                    session == nil
                        ? String(localized: "Not started by this Kelp · \(tmux.name)")
                        : String(localized: "Closed in Kelp, still running")
                )
                .font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let session {
                Button(String(localized: "Open")) { app.workbench.focus(session: session.id) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 6).frame(minHeight: Metrics.rowTwoLine)
    }

    private func portRow(_ port: HostStats.Port) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(port.port)").font(.ui(12).monospacedDigit()).frame(width: 48, alignment: .leading)
            Text(port.local ? String(localized: "this server only") : String(localized: "all addresses")).font(.ui(11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let here = forwarded[port.port] {
                Button("localhost:\(here)") {
                    if let wid = ServerActions.serverWorkspace(app, host) {
                        app.workbench.open("http://localhost:\(here)", workspace: wid)
                    }
                }
                .buttonStyle(PointerButtonStyle()).font(.ui(11).monospacedDigit()).foregroundStyle(Color.accentColor)
                .help(String(localized: "Open in the browser beside you"))
            } else {
                Button(String(localized: "Forward")) { forward(port.port) }.controlSize(.small)
                    .help(String(localized: "Reach it from this Mac as localhost"))
            }
        }
        .padding(.horizontal, 6).frame(height: Metrics.row)
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
                Text(repo.name).font(.ui(12))
                Spacer(minLength: 6)
                Text(RemoteHost.of(repo.path)?.path ?? "").font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 6).frame(height: Metrics.row).contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle())
    }

    private func forward(_ port: Int) {
        guard let wid = ServerActions.serverWorkspace(app, host) else { return }
        Task {
            if let forwarding = await app.call(PortsForward(worktreeId: wid, port: port)) {
                forwarded[port] = forwarding.port
            }
        }
    }
}
