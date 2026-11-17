import Core
import DesignKit
import KelpKit
import SwiftUI

/// The footer of the Files panel. It shows how much disk the workspace's project takes and how much of that rebuilds,
/// and a click opens the Disk Usage tab. It measures when it shows and the last measure is old. A remote project is
/// measured on its host, where the files above it are read from. Without a project, the footer shows nothing.
struct DiskFoot: View {
    let app: AppModel, sizes: DiskSizes
    @State private var hovering = false

    var body: some View {
        let repoId = app.worktree(app.workbench.workspaceId)?.repoId
        let host = repoId.flatMap { app.repo($0) }.flatMap { RemoteHost.of($0.path)?.host }
        let measured = repoId.flatMap { sizes.byRepo[$0] }
        // The footer shows once there's something to say, which is while measuring or when a measure found something.
        let shows = repoId.map { measured.map { !$0.items.isEmpty } ?? sizes.measuring.contains($0) } ?? false
        VStack(spacing: 0) {
            if let repoId, shows {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        app.workbench.open("disk:\(repoId)")
                    } label: {
                        label(measured?.items, measuring: sizes.measuring.contains(repoId), host: host)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Show Disk Usage"))
                }
            }
        }
        .task(id: repoId) { if let repoId { sizes.measure(repoId, app: app) } }
    }

    private func label(_ items: [RepoDiskUsage.Item]?, measuring: Bool, host: String?) -> some View {
        HStack(spacing: Metrics.gapWide) {
            if let items {
                DiskBar(items: items).frame(width: 40, height: 6)
                Text(DiskNames.size(items.bytes)).monospacedDigit()
                Text(DiskNames.foot(items, host: host)).foregroundStyle(.secondary).lineLimit(1)
            } else if measuring {
                ProgressView().controlSize(.mini)
                Text("Measuring…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.symbol(Metrics.iconTiny)).foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
        }
        .font(.ui(TextSize.caption))
        .padding(.horizontal, Metrics.inset)
        .frame(height: TextSize.of(Metrics.contentBar))
        .background(Color(nsColor: hovering ? .fillHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovering)
    }
}
