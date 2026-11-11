import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// "host:<name>" — a server at a glance: four meters with the last two minutes, the busiest processes with whose agent each
/// is, and beside them Kelp's agents there, what still runs in tmux, the ports and the projects. Read every 2 s while it's
/// on screen (`WatchTopic.hostDetail`); htop is a button away for the rest.
@MainActor
func serverTab(uri: String, app: AppModel) -> KelpKit.TabContent {   // not SwiftUI's
    let host = TabURI.body(uri)
    return HostedTabContent(
        uri: uri, title: host, icon: "server.rack", app: app, watching: [(.hostDetail, host)],
        ServerView(app: app, host: host))
}

struct ServerView: View {
    let app: AppModel, host: String
    /// CPU and memory shares of the last two minutes, a reading every 2 s.
    @State private var history: [(cpu: Double, memory: Double)] = []
    @State private var dialing = false

    private var stats: HostStats? { app.latest(HostEvent.self, host)?.stats }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let stats, stats.connected {
                ServerDetail(app: app, host: host, stats: stats, history: history)
            } else if stats == nil || dialing {
                LoadingLine(String(localized: "Connecting…")).offset(y: -Metrics.emptyLift).frame(
                    maxWidth: .infinity, maxHeight: .infinity)
            } else {
                offline
            }
        }
        .onAppear { dial() }
        .onChange(of: stats) { _, s in remember(s) }
    }

    private var header: some View {
        ContentBar {
            Text(host).font(.ui(TextSize.body, weight: .semibold))
            Text(serverLine(stats)).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(
                .middle)
            Spacer(minLength: 8)
            Button(String(localized: "Terminal")) { ServerActions.runOnServer(app, host) }
            Button("htop") { ServerActions.openHtop(app, host) }
            Menu {
                Button(String(localized: "Add Project on \(host)…")) { app.workbench.addProject(onServer: host) }
                if stats?.connected == true {
                    Button(String(localized: "Disconnect")) { ServerActions.disconnectServer(app, host) }
                }
                Divider()
                Button(String(localized: "Copy Host")) {
                    copyText(host)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.symbol())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(String(localized: "More"))
        }
    }

    /// Not connected, or it couldn't be: why, in ssh's words, and the way back.
    private var offline: some View {
        let error = stats?.error
        return EmptyState(
            error == nil ? String(localized: "Not connected to \(host)") : String(localized: "Can't reach \(host)"),
            symbol: error == nil ? "server.rack" : "exclamationmark.triangle"
        ) {
            VStack(spacing: 8) {
                Text(
                    error == nil
                        ? String(localized: "Kelp connects when you ask: it doesn't dial a machine by itself.")
                        : String(localized: "Check that the machine is on and on this network, then try again."))
                if let error {
                    Text(error).font(.ui(TextSize.caption).monospaced()).foregroundStyle(.secondary).textSelection(
                        .enabled)
                }
            }
        } actions: {
            Button(error == nil ? String(localized: "Connect") : String(localized: "Try Again")) { dial() }
                .keyboardShortcut(.defaultAction)
            Button(String(localized: "Open Terminal")) { ServerActions.runOnServer(app, host) }
        }
    }

    /// Opens the shared connection (the watch only reads over one that's open), then has the watch read it now: its first
    /// reading comes as every other does, pushed.
    private func dial() {
        guard !dialing else { return }
        dialing = true
        Task {
            if await app.quiet(HostStatsRead(host: host, connect: true)) != nil { app.watchAgain(.hostDetail, host) }
            dialing = false
        }
    }

    private func remember(_ stats: HostStats?) {
        guard let stats, stats.connected, let cpu = stats.cpu else { return }
        let memory = HostStats.percent(stats.memory, stats.memoryTotal).map { Double($0) / 100 } ?? 0
        history = Array((history + [(cpu / 100, memory)]).suffix(60))
    }
}
