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
    /// Whether a measure of this Mac's disk has taken a second, after which its wait shows (the latency rule).
    @State private var slow = false

    var body: some View {
        let repoId = app.worktree(app.workbench.workspaceId)?.repoId
        let host = repoId.flatMap { app.repo($0) }.flatMap { RemoteHost.of($0.path)?.host }
        let measured = repoId.flatMap { sizes.byRepo[$0] }
        let measuring = repoId.map { sizes.measuring.contains($0) } ?? false
        // The footer shows once there's something to say: when a measure found something, or while measuring, which on
        // this Mac's own disk says so only after a second and on a host's at once.
        let shows = repoId != nil && (measured.map { !$0.items.isEmpty } ?? (measuring && (host != nil || slow)))
        VStack(spacing: 0) {
            if let repoId, shows {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        app.workbench.open("disk:\(repoId)")
                    } label: {
                        label(measured?.items, measuring: sizes.measuring.contains(repoId), host: host)
                    }
                    .buttonStyle(FootPress())
                    .help(String(localized: "Show Disk Usage"))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Motion.duration(Motion.appear)), value: shows)   // the footer fades in and out
        .task(id: repoId) { if let repoId { sizes.measure(repoId, app: app) } }
        .task(id: measuring) {
            slow = false
            guard measuring else { return }
            do { try await Task.sleep(for: .seconds(LoadingView.patience)) } catch { return }
            slow = true
        }
    }

    private func label(_ items: [RepoDiskUsage.Item]?, measuring: Bool, host: String?) -> some View {
        HStack(spacing: Metrics.gapWide) {
            if let items {
                DiskBar(items: items).frame(width: 40, height: 6)
                // The size stays whole on one line in a narrow panel; what rebuilds gives way and is cut at its end.
                Text(DiskNames.size(items.bytes)).monospacedDigit().lineLimit(1).fixedSize().layoutPriority(1)
                Text(DiskNames.foot(items, host: host)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.tail)
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

/// The footer's press: while held, the row darkens to `fillSelected` at once, as a held row does, under the hover
/// grey that fades in under the pointer, and it dips and springs back as a row does.
private struct FootPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pressed(configuration: configuration) }

    private struct Pressed: View {
        let configuration: Configuration
        @State private var size = CGSize.zero
        var body: some View {
            configuration.label.background(Color(nsColor: configuration.isPressed ? .fillSelected : .clear))
                .scaleEffect(configuration.isPressed && !Motion.reduced ? Motion.pressDip(size) : 1)
                .animation(   // DesignKit's `pressSpring`, which is internal to it
                    Motion.reduced ? nil : .pressSpring,
                    value: configuration.isPressed
                )
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: {
                    size = $0
                }
        }
    }
}
