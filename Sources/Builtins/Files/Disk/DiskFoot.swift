import Core
import DesignKit
import KelpKit
import SwiftUI

/// The foot of Files: what the workspace's project takes on this Mac and how much of it rebuilds, a click from the Disk
/// Usage tab. Measured when it shows and the last measure is old; nothing for a remote project or none at all.
struct DiskFoot: View {
    let app: AppModel, sizes: DiskSizes
    @State private var hovering = false

    var body: some View {
        let repoId = app.worktree(app.workbench.workspaceId)?.repoId
        let measured = repoId.flatMap { sizes.byRepo[$0] }
        // Shown once there's something to say: measuring, or a measure with something in it.
        let shows = repoId.map { measured.map { !$0.items.isEmpty } ?? sizes.measuring.contains($0) } ?? false
        VStack(spacing: 0) {
            if let repoId, shows {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        app.workbench.open("disk:\(repoId)")
                    } label: {
                        label(measured?.items, measuring: sizes.measuring.contains(repoId))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Show Disk Usage"))
                }
            }
        }
        .task(id: repoId) { if let repoId { sizes.measure(repoId, app: app) } }
    }

    private func label(_ items: [RepoDiskUsage.Item]?, measuring: Bool) -> some View {
        HStack(spacing: Metrics.gapWide) {
            if let items {
                DiskBar(items: items).frame(width: 40, height: 6)
                Text(DiskNames.size(items.bytes)).monospacedDigit()
                let rebuilds = items.of(.rebuilds).bytes
                Text(
                    rebuilds > 0
                        ? String(localized: "\(DiskNames.size(rebuilds)) rebuilds") : String(localized: "on this Mac")
                )
                .foregroundStyle(.secondary).lineLimit(1)
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
