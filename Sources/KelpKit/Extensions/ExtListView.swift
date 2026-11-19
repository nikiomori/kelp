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
    @State private var selection: String?
    @State private var busy: Set<Int> = []   // toolbar actions whose command has run for over a second
    private let app: AppModel
    private var bench: Workbench { app.workbench }

    init(def: ExtManifest.ListDef, folder: URL, app: AppModel) {
        self.def = def
        self.folder = folder
        self.app = app
    }

    var body: some View {
        VStack(spacing: 0) {
            // The bar every panel has (DesignKit's Bar): the leading side is for the panel's subject (its tab names
            // it), and the actions sit at the end before ⋯ (Refresh): the first in words on the grey plate, as
            // TextButton draws it (a worded button has no symbol), the others as icons, or in words without a symbol.
            HStack(spacing: Metrics.gap) {
                Spacer()
                ForEach(Array((def.toolbar ?? []).enumerated()), id: \.offset) { index, action in
                    toolbarButton(action, index)
                }
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
                EmptyState(
                    title: String(localized: "Couldn’t Run the List’s Command"), symbol: nil, output: error,
                    retry: reload
                ).frame(maxHeight: .infinity)
            } else if items.isEmpty, !answered {
                // Only the first wait shows the rows' outline; a timed refresh keeps what is shown.
                if waitingSince != nil {
                    Waiting(rowHeight: def.subtitle == nil ? Metrics.row : Metrics.rowTwoLine).frame(
                        maxHeight: .infinity)
                } else {
                    Color.clear
                }
            } else if items.isEmpty {
                let symbol = def.icon.map { $0.contains("${") ? "tray" : $0 } ?? "tray"   // a field's icon names no symbol here
                EmptyState(title: def.empty ?? String(localized: "Nothing Here"), symbol: symbol, output: nil).frame(
                    maxHeight: .infinity)
            } else {
                if let error {
                    FailureLine(error, retry: reload).padding(.horizontal, Metrics.inset).padding(.top, Metrics.gap)
                }
                List(selection: $selection) {
                    ForEach(Array(zip(keys(items), items)), id: \.0) { key, item in
                        draggable(row(item), item).tag(key).contextMenu { rowMenu(item) }
                    }
                }
                .listStyle(.sidebar)
                // Rows as tall as the inspector's (24, or 40 with a line under the name), growing with Text size.
                .environment(
                    \.defaultMinListRowHeight, TextSize.of(def.subtitle == nil ? Metrics.row : Metrics.rowTwoLine)
                )
                .contextMenu(forSelectionType: String.self) { _ in
                } primaryAction: { sel in
                    if let key = sel.first, let index = keys(items).firstIndex(of: key),
                        let action = def.actions?.first
                    {
                        ExtActions(app).perform(action, item: items[index], folder: folder, after: { reload() })
                    }
                }
            }
        }
        .task(id: bench.workspaceId) {
            await Self.refreshing(every: def.refresh, away: { app.away }, run: refresh)
        }
    }

    /// A row's right-click menu: every action, with its symbol when it names one.
    @ViewBuilder private func rowMenu(_ item: JSONValue) -> some View {
        ForEach(Array((def.actions ?? []).enumerated()), id: \.offset) { _, a in
            Button {
                ExtActions(app).perform(a, item: item, folder: folder, after: { reload() })
            } label: {
                if let icon = a.icon { Label(a.title, systemImage: icon) } else { Text(a.title) }
            }
        }
    }

    /// A toolbar action. A `run` command that takes over a second shows a spinner in the button's place, and the
    /// button can't be pressed again until it ends.
    @ViewBuilder private func toolbarButton(_ action: ExtManifest.ActionDef, _ index: Int) -> some View {
        let run: @MainActor () -> Void = {
            ExtActions(app).perform(
                action, item: nil, folder: folder,
                busy: { on in
                    if on { busy.insert(index) } else { busy.remove(index) }
                }
            ) { reload() }
        }
        let waiting = busy.contains(index)
        Group {
            if index == 0 {
                Button(action: run) { Text(action.title).opacity(waiting ? 0 : 1) }.buttonStyle(BarButtonStyle())
            } else if let icon = action.icon {
                Button(action: run) {
                    Image(systemName: icon).font(.symbol()).foregroundStyle(.secondary).opacity(waiting ? 0 : 1)
                        .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                }
                .buttonStyle(PointerButtonStyle()).help(action.title).accessibilityLabel(action.title)
            } else {
                Button(action: run) { Text(action.title).font(.ui(TextSize.row)).opacity(waiting ? 0 : 1) }
                    .buttonStyle(PointerButtonStyle())
            }
        }
        .overlay { if waiting { ProgressView().controlSize(.small) } }
        .disabled(waiting)
    }

    /// Each row's key: its title, numbered where titles repeat. A refresh keeps a row, and its selection, while its
    /// other fields change (a container's "Up 5 minutes"); keyed by position, the selection moved to another row when
    /// one above it went.
    private func keys(_ items: [JSONValue]) -> [String] {
        let actions = ExtActions(app)
        var seen: [String: Int] = [:]
        return items.map { item in
            let title = actions.expand(def.title ?? "${name}", item: item, quote: false)
            seen[title, default: 0] += 1
            return seen[title] == 1 ? title : "\(title)\u{1}\(seen[title] ?? 0)"
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
        var rowHeight: CGFloat
        func makeNSView(context: Context) -> LoadingView {
            let view = LoadingView(rows: true, rowHeight: rowHeight)
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
        let new = Self.parse(result.stdout)
        // Up to three rows coming or going fade while their neighbours move; more change at once.
        let changed = Set(keys(new)).symmetricDifference(keys(items)).count
        withAnimation(changed <= 3 && !Motion.reduced ? .easeOut(duration: Motion.appear) : nil) { items = new }
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
