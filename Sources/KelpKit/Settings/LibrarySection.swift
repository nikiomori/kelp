import Core
import DesignKit
import SwiftUI

/// Settings › Extensions › Library. It lists what github.com/nikiomori/kelp-extensions holds, read when the pane
/// shows, to install or bring up to date.
struct LibrarySection: View {
    @Environment(AppModel.self) private var app
    private var registry: ExtensionRegistry { app.extensions }
    @State private var entries: [ExtensionLibrary.Entry]?
    @State private var error: String?
    /// The first required command each extension lacks on this Mac.
    @State private var missing: [String: String] = [:]
    @State private var installing: String?
    @State private var query = ""
    /// The category shown, or nil for all of them.
    @State private var category: String?

    var body: some View {
        Section {
            if let error {
                // The same error block every panel shows: the triangle, what failed, why, and Try Again.
                EmptyState(
                    String(localized: "Couldn’t Load the Library"), symbol: "exclamationmark.triangle", lifted: false
                ) {
                    Text(error).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if let entries {
                if entries.isEmpty {
                    EmptyState(
                        String(localized: "Nothing in the Library Yet"), symbol: "puzzlepiece.extension", lifted: false)
                } else {
                    filters(entries)
                    let shown = entries.filter {
                        (category == nil || Self.category($0) == category) && $0.matches(query)
                    }
                    let (reviewed, found) = Self.split(shown)
                    if shown.isEmpty {
                        EmptyState(
                            String(localized: "No Extension Matches “\(query)”"), symbol: "magnifyingglass",
                            lifted: false)
                    }
                    ForEach(reviewed, id: \.id) { row($0) }
                    if !found.isEmpty { unreviewed(found) }
                }
            } else {
                LoadingLine(String(localized: "Reading the library…"))
            }
        } footer: {
            HStack {
                Text(
                    "Extensions people shared, each reviewed before it’s added. Or any repository: `kelp ext install owner/repo`"
                )
                .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                Spacer()
                if let url = URL(string: "https://github.com/\(ExtensionFiles.libraryRepo)") {
                    Link("Share Yours on GitHub", destination: url).font(.ui(TextSize.caption)).buttonStyle(.kelpLink)
                }
            }
        }
        .task { await load() }
    }

    /// The search field, and the categories once the library has more than one.
    private func filters(_ entries: [ExtensionLibrary.Entry]) -> some View {
        let kinds = Self.categories.filter { c in entries.contains { Self.category($0) == c } }
        return HStack {
            TextField("Search the library", text: $query, prompt: Text("Search the library")).textFieldStyle(
                .roundedBorder
            ).labelsHidden()
            if kinds.count > 1 {
                Picker("Category", selection: $category) {
                    Text("All").tag(String?.none)
                    ForEach(kinds, id: \.self) { Text(Self.title($0)).tag(String?.some($0)) }
                }.labelsHidden().fixedSize()
            }
        }
    }
    /// The library's categories in the order the menu lists them. An index from before categories existed files
    /// everything as tools.
    static let categories = ["tools", "integrations", "languages", "agents", "themes", "icons"]
    static func category(_ entry: ExtensionLibrary.Entry) -> String {
        entry.category.map { categories.contains($0) ? $0 : "tools" } ?? "tools"
    }
    static func title(_ category: String) -> String {
        switch category {
        case "integrations": String(localized: "Integrations")
        case "languages": String(localized: "Languages")
        case "agents": String(localized: "Agents")
        case "themes": String(localized: "Themes")
        case "icons": String(localized: "Icons")
        default: String(localized: "Tools")
        }
    }

    /// Splits the entries into the reviewed ones, by name, and those found on GitHub by their topic, fastest growing
    /// first.
    static func split(_ entries: [ExtensionLibrary.Entry]) -> (
        reviewed: [ExtensionLibrary.Entry], found: [ExtensionLibrary.Entry]
    ) {
        (
            entries.filter { $0.reviewed != false },
            entries.filter { $0.reviewed == false }.sorted {
                ($0.weekly ?? 0, $0.stars ?? 0) > ($1.weekly ?? 0, $1.stars ?? 0)
            }
        )
    }

    /// Lists GitHub's repositories under the `kelp-extension` topic. Nobody reviewed them, and the list says so first.
    private func unreviewed(_ found: [ExtensionLibrary.Entry]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
                Text("From GitHub · not reviewed").fontWeight(.semibold)
                Text("topic kelp-extension, fastest growing first").font(.ui(TextSize.caption)).foregroundStyle(
                    .secondary)
            }
            // A caution, not something waiting for you: grey with the triangle, as orange is only for "waits for you".
            Label(
                "Nobody at Kelp has looked at these. Before installing, Kelp shows every command one runs.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            ForEach(found, id: \.id) { row($0) }
        }
        .padding(.top, Metrics.gapWide)
    }

    private func row(_ entry: ExtensionLibrary.Entry) -> some View {
        let have = registry.extensions.first { $0.id == entry.id && !$0.builtin }
        return HStack(alignment: .top, spacing: Metrics.gapWide) {
            SymbolIcon(entry.icon ?? "puzzlepiece.extension", size: Metrics.iconLarge).foregroundStyle(
                .secondary
            ).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Metrics.gap) {
                    Text(entry.name)
                    Text(entry.version).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                    if let stars = entry.stars { popularity(stars, weekly: entry.weekly ?? 0) }
                }
                if let summary = entry.description, !summary.isEmpty {
                    Text(summary).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
                if let tool = missing[entry.id] {
                    Text("Needs `\(tool)` — not found on this Mac.").font(.ui(TextSize.caption)).foregroundStyle(
                        .secondary)
                }
            }
            Spacer()
            if installing == entry.id {
                ProgressView().controlSize(.small)
            } else if have == nil {
                Button(entry.reviewed == false ? "Install…" : "Install") { install(entry) }
            } else if let source = have?.source, source != entry.source || entry.reviewed == false {
                // always offered for one found by its topic, whose branch may have moved
                Button(entry.reviewed == false ? "Update…" : "Update") { install(entry) }
            } else {
                HStack(spacing: Metrics.gap) {
                    StateDot(on: true)
                    Text("Already installed").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// GitHub's stars as SF Symbols' star beside the count (not a typed ★), and how many came this week.
    private func popularity(_ stars: Int, weekly: Int) -> some View {
        HStack(spacing: Metrics.gap) {
            HStack(spacing: Metrics.lineGap) {
                Image(systemName: "star").font(.symbol(Metrics.iconSmall)).accessibilityLabel("Stars")
                Text(stars, format: .number)
            }
            if weekly > 0 { Text("+\(weekly) this week") }
        }
        .font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary)
    }

    private func install(_ entry: ExtensionLibrary.Entry) {
        installing = entry.id
        Task {
            _ = await registry.install(source: entry.source, files: entry.files)
            installing = nil
        }
    }

    private func load() async {
        error = nil
        do {
            let all = try await app.get(ExtensionLibrary())
            // Ask where the daemon finds the tools the extensions need. Nothing is shown when it can't tell.
            if let found = await app.quiet(ProcessWhich(commands: Array(Set(all.flatMap { $0.requires ?? [] })))) {
                missing = Dictionary(
                    uniqueKeysWithValues: all.compactMap { entry in
                        (entry.requires ?? []).first { found[$0] == nil }.map { (entry.id, $0) }
                    })
            }
            entries = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            self.error = AppModel.message(error)
        }
    }
}
