import Agents
import AppKit
import Core
import DesignKit
import SwiftUI
import WebKit
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
                ForEach(Array((def.toolbar ?? []).enumerated()), id: \.offset) { index, action in
                    Button {
                        ExtActions(app).perform(action, item: nil, folder: folder) { reload() }
                    } label: {
                        if index == 0 {
                            Label(action.title, systemImage: action.icon ?? "play")
                        } else {
                            Image(systemName: action.icon ?? "play").frame(width: 22, height: 22)
                        }
                    }
                    .buttonStyle(PointerButtonStyle()).help(action.title)
                    if index == 0 { Spacer() }
                }
                if def.toolbar?.isEmpty ?? true { Spacer() }
                if loading { ProgressView().controlSize(.small) }
                Menu {
                    Button("Refresh") { reload() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
            }
            .font(.system(size: Metrics.iconPoint))
            .foregroundStyle(.secondary)
            .padding(.leading, Metrics.inset).padding(.trailing, Metrics.insetTrailing).frame(
                height: TextSize.of(Metrics.panelHeader))
            Divider()
            if let error {
                EmptyState(title: String(localized: "Couldn't load"), symbol: nil, output: error).frame(
                    maxHeight: .infinity)
            } else if items.isEmpty, !running {
                let symbol = def.icon.map { $0.contains("${") ? "tray" : $0 } ?? "tray"   // a field's icon names no symbol here
                EmptyState(title: def.empty ?? String(localized: "Nothing here"), symbol: symbol, output: nil).frame(
                    maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        draggable(row(item), item).tag(i)
                            .contextMenu {
                                ForEach(Array((def.actions ?? []).enumerated()), id: \.offset) { _, a in
                                    Button {
                                        ExtActions(app).perform(a, item: item, folder: folder) { reload() }
                                    } label: {
                                        Label(a.title, systemImage: a.icon ?? "circle")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: Int.self) { _ in
                } primaryAction: { sel in
                    if let index = sel.first, items.indices.contains(index), let action = def.actions?.first {
                        ExtActions(app).perform(action, item: items[index], folder: folder) { reload() }
                    }
                }
            }
        }
        .task(id: bench.workspaceId) {
            while !Task.isCancelled {
                reload()
                guard let seconds = def.refresh, seconds > 0 else { break }
                try? await Task.sleep(for: .seconds(max(seconds, 1)))
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
        let actions = ExtActions(app)
        let subtitle = def.subtitle.map { actions.expand($0, item: item, quote: false) } ?? ""
        return HStack(spacing: 8) {
            // An icon that's the same on every row is the panel's own (its tab shows it): only one that names a field tells rows apart.
            if let icon = def.icon, icon.contains("${") {
                let name = actions.expand(icon, item: item, quote: false)
                if let image = Self.image(name) {
                    Image(nsImage: image).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: name.hasPrefix("app:") ? "app.dashed" : name).foregroundStyle(.secondary).frame(
                        width: 16)
                }
            }
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(actions.expand(def.title ?? "${name}", item: item, quote: false)).lineLimit(1)
                if !subtitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(subtitle).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let st = status(item) { StatusIcon(status: st) }
        }
    }

    /// `drag`: the row drags that file (into Finder, a terminal, an agent's prompt).
    @ViewBuilder private func draggable(_ view: some View, _ item: JSONValue) -> some View {
        let path = def.drag.map { ExtActions(app).expand($0, item: item, quote: false) } ?? ""
        if !path.isEmpty {
            view.onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider() }
        } else {
            view
        }
    }

    @MainActor private static var images: [String: NSImage?] = [:]
    /// A row icon that isn't an SF Symbol: `app:<bundle id>` (that app's icon) or a file's path (its Finder icon).
    @MainActor private static func image(_ name: String) -> NSImage? {
        guard name.hasPrefix("app:") || name.hasPrefix("/") else { return nil }
        if let cached = images[name] { return cached }
        let path =
            name.hasPrefix("/")
            ? name : NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(name.dropFirst(4)))?.path
        let image = path.map { NSWorkspace.shared.icon(forFile: $0) }
        images[name] = image
        return image
    }

    private func status(_ item: JSONValue) -> AgentStatus? {
        guard let rule = def.status, let value = item[rule.field].map(ExtActions.text),
            let mapped = rule.map[value] ?? rule.map[value.lowercased()]
        else { return nil }
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
            let result = await Shell.run(app, cmd, cwd: cwd, extension: folder.lastPathComponent)
            slow.cancel()
            loading = false
            running = false
            if result.code != 0, result.stdout.isEmpty {
                error =
                    result.stderr.isEmpty
                    ? String(localized: "Exit code \(result.code)") : String(result.stderr.suffix(600))
                return
            }
            error = nil
            items = Self.parse(result.stdout)
        }
    }

    /// A JSON array, or one JSON object per line.
    static func parse(_ s: String) -> [JSONValue] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
            case .array(let array)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            return array
        }
        return trimmed.split(whereSeparator: \.isNewline).compactMap { line in
            line.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }
    }
}
