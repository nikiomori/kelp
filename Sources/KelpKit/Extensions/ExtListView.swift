import AppKit
import Core
import DesignKit
import SwiftUI
import WebKit

// MARK: list views

struct ExtListView: View {
    let def: ExtManifest.ListDef
    let folder: URL
    @State private var items: [JSONValue] = []
    @State private var error: String?
    @State private var waitingSince: Date?   // when the rows' outline came up, a second into the first wait
    @State private var answered = false   // the command has answered once (no "empty" before that)
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
            // The bar every panel has (DesignKit's Bar): the first action in words on the grey plate, as TextButton
            // draws it (a worded button has no symbol), the others as icons, Refresh in ⋯.
            HStack(spacing: Metrics.gap) {
                ForEach(Array((def.toolbar ?? []).enumerated()), id: \.offset) { index, action in
                    let run: @MainActor () -> Void = {
                        ExtActions(app).perform(action, item: nil, folder: folder) { reload() }
                    }
                    if index == 0 {
                        Button(action.title, action: run).buttonStyle(BarButtonStyle())
                        Spacer()
                    } else {
                        Button(action: run) {
                            Image(systemName: action.icon ?? "play.fill").font(.symbol()).foregroundStyle(.secondary)
                                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                        }
                        .buttonStyle(PointerButtonStyle()).help(action.title).accessibilityLabel(action.title)
                    }
                }
                if def.toolbar?.isEmpty ?? true { Spacer() }
                Menu {
                    Button("Refresh") { reload() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.symbol()).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More Actions")
                .accessibilityLabel("More Actions")
            }
            .padding(.leading, Metrics.inset).padding(.trailing, Metrics.insetTrailing).frame(
                height: TextSize.of(Metrics.panelHeader))
            Divider()
            if let error, items.isEmpty {
                EmptyState(title: String(localized: "Couldn’t load"), symbol: nil, output: error, retry: reload).frame(
                    maxHeight: .infinity)
            } else if items.isEmpty, !answered {
                // Only the first wait shows the rows' outline; a timed refresh keeps what is shown.
                if waitingSince != nil { Waiting().frame(maxHeight: .infinity) } else { Color.clear }
            } else if items.isEmpty {
                let symbol = def.icon.map { $0.contains("${") ? "tray" : $0 } ?? "tray"   // a field's icon names no symbol here
                EmptyState(title: def.empty ?? String(localized: "Nothing here"), symbol: symbol, output: nil).frame(
                    maxHeight: .infinity)
            } else {
                if let error {
                    FailureLine(error, retry: reload).padding(.horizontal, Metrics.inset).padding(.top, Metrics.gap)
                }
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
                // Rows as tall as the inspector's (24, or 40 with a line under the name), growing with Text size.
                .environment(
                    \.defaultMinListRowHeight, TextSize.of(def.subtitle == nil ? Metrics.row : Metrics.rowTwoLine)
                )
                .contextMenu(forSelectionType: Int.self) { _ in
                } primaryAction: { sel in
                    if let index = sel.first, items.indices.contains(index), let action = def.actions?.first {
                        ExtActions(app).perform(action, item: items[index], folder: folder) { reload() }
                    }
                }
            }
        }
        .task(id: bench.workspaceId) {
            await Self.refreshing(every: def.refresh, away: { app.away }, run: refresh)
        }
    }

    /// DesignKit's empty state, as every panel has it; a failed command's output shows as its (selectable) fix line,
    /// with Try Again under it.
    private struct EmptyState: NSViewRepresentable {
        let title: String, symbol: String?, output: String?
        var retry: (@MainActor () -> Void)?
        func makeNSView(context: Context) -> EmptyStateView { EmptyStateView() }
        func updateNSView(_ view: EmptyStateView, context: Context) {
            guard let output else { return view.show(title, symbol: symbol) }
            let again = retry.map { [ClosureButton(title: String(localized: "Try Again"), action: $0)] } ?? []
            view.showError(title, text: nil, fix: output, buttons: again)
        }
    }

    /// DesignKit's loading view: the shape of the rows to come, while the first answer is slow.
    private struct Waiting: NSViewRepresentable {
        func makeNSView(context: Context) -> LoadingView {
            let view = LoadingView(rows: true)
            view.show(String(localized: "Running the list’s command…"))
            return view
        }
        func updateNSView(_ view: LoadingView, context: Context) {}
    }

    private func row(_ item: JSONValue) -> some View {
        let actions = ExtActions(app)
        let subtitle = def.subtitle.map { actions.expand($0, item: item, quote: false) } ?? ""
        return HStack(spacing: Metrics.gap) {
            // An icon that's the same on every row is the panel's own icon, which its tab already shows. Only an icon
            // that names a field tells rows apart, so only that one shows on the row.
            if let icon = def.icon, icon.contains("${") {
                let name = actions.expand(icon, item: item, quote: false)
                if let image = Self.image(name) {
                    Image(nsImage: image).resizable().frame(
                        width: TextSize.of(Metrics.appIcon), height: TextSize.of(Metrics.appIcon))
                } else {
                    Image(systemName: name.hasPrefix("app:") ? "app.dashed" : name).font(.symbol())
                        .foregroundStyle(.secondary).frame(width: TextSize.of(Metrics.appIcon))
                }
            }
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(actions.expand(def.title ?? "${name}", item: item, quote: false)).font(.ui(TextSize.row))
                    .lineLimit(1)
                if !subtitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(subtitle).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Metrics.gap)
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

    /// Runs `run` now, then again `seconds` (at least 1) after each run ends, so a command slower than its interval never
    /// runs twice at once. While the window is away nobody sees the list: it only looks again every 5 s whether to run.
    /// No `seconds` (or 0): once.
    static func refreshing(
        every seconds: Double?, away: @MainActor () -> Bool, run: @MainActor () async -> Void,
        pause: @MainActor (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) async {
        var first = true
        while !Task.isCancelled {
            if first || !away() { await run() }
            first = false
            guard let seconds, seconds > 0 else { return }
            await pause(away() ? 5 : max(seconds, 1))
        }
    }

    private func reload() { Task { await refresh() } }

    private func refresh() async {
        let cmd = ExtActions(app).expand(def.command, item: nil, quote: true)
        let cwd = IDEContext.of(app).workspace?.path ?? folder.path
        // The outline only for a first wait you'd notice; once shown, it stays long enough not to blink.
        let slow = whileSlow { if !answered { waitingSince = .now } }
        let result = await Shell.run(app, cmd, cwd: cwd, extension: folder.lastPathComponent)
        slow.cancel()
        if let since = waitingSince {
            let left = LoadingView.held - Date.now.timeIntervalSince(since)
            if left > 0 { do { try await Task.sleep(for: .seconds(left)) } catch { return } }
            waitingSince = nil
        }
        answered = true
        if result.code != 0, result.stdout.isEmpty {
            error =
                result.stderr.isEmpty
                ? String(localized: "Exit code \(result.code)") : String(result.stderr.suffix(600))
            return
        }
        error = nil
        items = Self.parse(result.stdout)
    }

    /// A JSON array, or one JSON object per line.
    static func parse(_ text: String) -> [JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
