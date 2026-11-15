import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// "disk:<project>" — what the project takes on this Mac: its parts sorted by what removing them costs, beside a map of
/// them; what's chosen goes to the Trash in one click (the Finder puts it back).
@MainActor
func diskUsageTab(uri: String, app: AppModel, sizes: DiskSizes) -> KelpKit.TabContent {   // not SwiftUI's
    HostedTabContent(
        uri: uri, title: String(localized: "Disk Usage"), icon: "internaldrive", app: app,
        DiskUsageView(app: app, repoId: TabURI.body(uri), sizes: sizes))
}

struct DiskUsageView: View {
    let app: AppModel, repoId: String, sizes: DiskSizes
    @State private var chosen: Set<String> = []
    @State private var trashing = false

    private var repo: Repo? { app.repo(repoId) }
    private var root: String { repo.map { Paths.real($0.path) ?? $0.path } ?? "" }

    var body: some View {
        let measured = sizes.byRepo[repoId]
        VStack(spacing: 0) {
            header(measured)
            Divider()
            if let measured, !measured.items.isEmpty {
                HStack(spacing: 0) {
                    DiskList(items: measured.items, root: root, chosen: $chosen, trash: trash, trashing: trashing)
                        .frame(width: 340)
                    Divider()
                    DiskMap(items: measured.items, root: root, chosen: $chosen).padding(Metrics.gap)
                }
            } else if measured != nil {
                EmptyState(String(localized: "Nothing to Measure"), symbol: "internaldrive") {
                    Text("A remote project’s files are on its host.")
                } actions: {
                }
            } else {
                EmptyState(String(localized: "Measuring \(repo?.name ?? "")…"), symbol: "internaldrive") {
                    Text("The first time takes a moment.")
                } actions: {
                }
            }
        }
        .task(id: repoId) { sizes.measure(repoId, app: app) }
        .onChange(of: measured?.at, initial: true) {
            // What rebuilds is chosen to start with; what's gone since is no longer.
            let items = measured?.items ?? []
            chosen = chosen.isEmpty ? Set(items.of(.rebuilds).map(\.path)) : chosen.intersection(items.map(\.path))
        }
    }

    private func header(_ measured: DiskSizes.Measured?) -> some View {
        ContentBar {
            Text(repo?.name ?? "").font(.ui(TextSize.row, weight: .medium))
            if let measured {
                Text("measured \(measured.at.formatted(.relative(presentation: .named)))")
                    .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            if sizes.measuring.contains(repoId) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    sizes.measure(repoId, app: app, again: true)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.symbol())
                }
                .buttonStyle(PointerButtonStyle()).help(String(localized: "Measure Again"))
            }
        }
    }

    private func trash() {
        guard let items = sizes.byRepo[repoId]?.items else { return }
        let paths = items.map(\.path).filter(chosen.contains)
        trashing = true
        Task {
            defer { trashing = false }
            guard let result = await app.call(RepoDiskTrash(id: repoId, paths: paths)) else { return }
            let gone = items.filter { result.removed.contains($0.path) }, freed = DiskNames.size(gone.bytes)
            if let why = result.kept.values.first {
                Banner.show(
                    String(localized: "Moved \(gone.count) to the Trash, kept \(result.kept.count): \(why)"),
                    style: .error)
            } else if gone.count == 1, let one = gone.first {
                Banner.show(
                    String(localized: "Moved \(DiskNames.name(one, root: root)) to the Trash — \(freed) freed"))
            } else {
                Banner.show(String(localized: "Moved \(gone.count) items to the Trash — \(freed) freed"))
            }
            chosen.subtract(result.removed)
            sizes.measure(repoId, app: app, again: true)
        }
    }
}

/// The total, then the parts by group (a box for each that can go), and the button that moves the chosen ones.
struct DiskList: View {
    let items: [RepoDiskUsage.Item], root: String
    @Binding var chosen: Set<String>
    let trash: () -> Void, trashing: Bool

    var body: some View {
        let picked = items.filter { chosen.contains($0.path) }
        VStack(alignment: .leading, spacing: 0) {
            summary.padding(Metrics.inset)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(DiskGroup.allCases, id: \.self) { group in
                        let these = items.of(group)
                        if !these.isEmpty {
                            HStack(spacing: Metrics.gap) {
                                // The fill its parts have on the map, shaped as the foot's bar (a square read as a box).
                                DiskFill(group: group).frame(
                                    width: Metrics.iconSmall + Metrics.gap, height: Metrics.gap
                                )
                                .clipShape(Capsule())
                                Text(group.title)
                                Spacer()
                                Text(DiskNames.size(these.bytes)).monospacedDigit()
                            }
                            .font(.ui(TextSize.caption, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, Metrics.inset).frame(height: Metrics.rowSection)
                            ForEach(these, id: \.path) { DiskRow(item: $0, root: root, chosen: $chosen) }
                        }
                    }
                }
                .padding(.horizontal, Metrics.gap)
            }
            Divider()
            HStack(spacing: Metrics.gapWide) {
                Text(
                    picked.isEmpty
                        ? String(localized: "Nothing chosen")
                        : String(localized: "\(DiskNames.size(picked.bytes)) chosen")
                )
                .font(.ui(TextSize.caption)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(
                    picked.count == 1
                        ? String(localized: "Move 1 Item to Trash")
                        : String(localized: "Move \(picked.count) Items to Trash"), action: trash
                )
                .buttonStyle(.borderedProminent).disabled(picked.isEmpty || trashing)
            }
            .padding(.horizontal, Metrics.inset).frame(height: Metrics.panelHeader + Metrics.gapWide)
        }
    }

    private var summary: some View {
        let rebuilds = items.of(.rebuilds).bytes, check = items.of(.check).bytes
        return VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
                Text(DiskNames.size(items.bytes)).font(.ui(TextSize.title, weight: .semibold)).monospacedDigit()
                Text("on this Mac").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            }
            Text(
                rebuilds > 0
                    ? String(
                        localized:
                            "\(DiskNames.size(rebuilds)) can be rebuilt, \(DiskNames.size(check)) needs a look first.")
                    : String(localized: "Nothing that rebuilds by itself. \(DiskNames.size(check)) needs a look first.")
            )
            .font(.ui(TextSize.body)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A part: its box when it can go, its name and what it is, its size; Show in Finder under the pointer.
struct DiskRow: View {
    let item: RepoDiskUsage.Item, root: String
    @Binding var chosen: Set<String>
    @State private var hovering = false

    var body: some View {
        let canGo = item.removable && !item.what.leftAlone
        HStack(spacing: Metrics.gapWide) {
            // One that can't go keeps the box's room, hidden: the names stand in one column.
            Toggle(
                "",
                isOn: Binding(
                    get: { chosen.contains(item.path) },
                    set: { on in if on { chosen.insert(item.path) } else { chosen.remove(item.path) } })
            )
            .toggleStyle(.checkbox).labelsHidden().opacity(canGo ? 1 : 0).disabled(!canGo)
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(DiskNames.name(item, root: root)).font(.ui(TextSize.row)).lineLimit(1).truncationMode(.middle)
                Text(DiskNames.detail(item)).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Metrics.gap)
            Text(DiskNames.size(item.bytes)).font(.ui(TextSize.row)).monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "magnifyingglass").font(.symbol())
            }
            .buttonStyle(PointerButtonStyle()).help(String(localized: "Show in Finder")).opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, Metrics.gap).frame(minHeight: Metrics.rowTwoLine)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM)
                .fill(Color(nsColor: hovering ? .fillHover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
