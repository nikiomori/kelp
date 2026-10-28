import AppKit
import SwiftUI
import WebKit
import Core
import DesignKit
import Agents
import WorkbenchKit

// MARK: list views

struct ExtListView: View {
    let def: ExtManifest.ListDef
    let folder: URL
    @State private var items: [JSONValue] = []
    @State private var error: String?
    @State private var loading = false   // the spinner, after a second
    @State private var running = false   // the command hasn't answered yet (no "empty" meanwhile)
    @State private var selection: Int?
    private let app: AppModel
    private var bench: Workbench { app.workbench }

    init(def: ExtManifest.ListDef, folder: URL, app: AppModel) {
        self.def = def
        self.folder = folder
        self.app = app
    }

    var body: some View {
        VStack(spacing: 0) {
            // The bar every panel has (DesignKit's Bar): the first action in words, the others as icons, Refresh in ⋯.
            HStack(spacing: Metrics.gap) {
                ForEach(Array((def.toolbar ?? []).enumerated()), id: \.offset) { i, a in
                    Button { ExtActions(app).perform(a, item: nil, folder: folder) { reload() } } label: {
                        if i == 0 { Label(a.title, systemImage: a.icon ?? "play") } else { Image(systemName: a.icon ?? "play").frame(width: 22, height: 22) }
                    }
                    .buttonStyle(.borderless).help(a.title)
                    if i == 0 { Spacer() }
                }
                if def.toolbar?.isEmpty ?? true { Spacer() }
                if loading { ProgressView().controlSize(.small) }
                Menu { Button("Refresh") { reload() } } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
            }
            .font(.system(size: Metrics.iconPoint))
            .foregroundStyle(.secondary)
            .padding(.leading, Metrics.inset).padding(.trailing, Metrics.insetTrailing).frame(height: TextSize.of(Metrics.panelHeader))
            Divider()
            if let error {
                EmptyState(title: String(localized: "Couldn't load"), symbol: nil, output: error).frame(maxHeight: .infinity)
            } else if items.isEmpty, !running {
                let symbol = def.icon.map { $0.contains("${") ? "tray" : $0 } ?? "tray"   // a field's icon names no symbol here
                EmptyState(title: def.empty ?? String(localized: "Nothing here"), symbol: symbol, output: nil).frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        row(item).tag(i)
                            .contextMenu {
                                ForEach(Array((def.actions ?? []).enumerated()), id: \.offset) { _, a in
                                    Button { ExtActions(app).perform(a, item: item, folder: folder) { reload() } } label: {
                                        Label(a.title, systemImage: a.icon ?? "circle")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { sel in
                    if let i = sel.first, items.indices.contains(i), let a = def.actions?.first {
                        ExtActions(app).perform(a, item: items[i], folder: folder) { reload() }
                    }
                }
            }
        }
        .task(id: bench.workspaceId) {
            while !Task.isCancelled {
                reload()
                guard let r = def.refresh, r > 0 else { break }
                try? await Task.sleep(for: .seconds(max(r, 1)))
            }
        }
    }

    /// DesignKit's empty state, as every panel has it; a failed command's output shows as its (selectable) fix line.
    private struct EmptyState: NSViewRepresentable {
        let title: String, symbol: String?, output: String?
        func makeNSView(context: Context) -> EmptyStateView { EmptyStateView() }
        func updateNSView(_ v: EmptyStateView, context: Context) {
            if let output { v.showError(title, text: nil, fix: output) } else { v.show(title, symbol: symbol) }
        }
    }

    private func row(_ item: JSONValue) -> some View {
        let x = ExtActions(app)
        let subtitle = def.subtitle.map { x.expand($0, item: item, quote: false) } ?? ""
        return HStack(spacing: 8) {
            // An icon that's the same on every row is the panel's own (its tab shows it): only one that names a field tells rows apart.
            if let icon = def.icon, icon.contains("${") {
                Image(systemName: x.expand(icon, item: item, quote: false)).foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(x.expand(def.title ?? "${name}", item: item, quote: false)).lineLimit(1)
                if !subtitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let st = status(item) { StatusIcon(status: st) }
        }
    }

    private func status(_ item: JSONValue) -> AgentStatus? {
        guard let s = def.status, let v = item[s.field].map(ExtActions.text), let mapped = s.map[v] ?? s.map[v.lowercased()] else { return nil }
        switch mapped {
        case "working": return .working
        case "waiting": return .waiting
        case "done": return .done
        case "idle": return .idle
        default: return .exited
        }
    }

    private func reload() {
        let cmd = ExtActions(app).expand(def.command, item: nil, quote: true)
        let cwd = IDEContext.of(app).workspace?.path ?? folder.path
        let slow = whileSlow { loading = true }   // a spinner only for a wait you'd notice
        running = true
        Task {
            let r = await Shell.run(app, cmd, cwd: cwd, extension: folder.lastPathComponent)
            slow.cancel()
            loading = false
            running = false
            if r.code != 0, r.stdout.isEmpty { error = r.stderr.isEmpty ? String(localized: "Exit code \(r.code)") : String(r.stderr.suffix(600)); return }
            error = nil
            items = Self.parse(r.stdout)
        }
    }

    /// A JSON array, or one JSON object per line.
    static func parse(_ s: String) -> [JSONValue] {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("["), let d = t.data(using: .utf8), case .array(let a)? = try? JSONDecoder().decode(JSONValue.self, from: d) { return a }
        return t.split(whereSeparator: \.isNewline).compactMap { line in
            line.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }
    }
}
