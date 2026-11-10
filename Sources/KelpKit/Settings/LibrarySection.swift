import Core
import DesignKit
import SwiftUI

/// Settings › Extensions › Library: what github.com/nikiomori/kelp-extensions holds, read when the pane shows,
/// to install or bring up to date.
struct LibrarySection: View {
    @Environment(AppModel.self) private var app
    private var registry: ExtensionRegistry { app.extensions }
    @State private var entries: [ExtensionLibrary.Entry]?
    @State private var error: String?
    /// The first required command each one lacks on this Mac.
    @State private var missing: [String: String] = [:]
    @State private var installing: String?
    @State private var query = ""
    /// The category shown; nil: all of them.
    @State private var category: String?

    var body: some View {
        Section {
            if let error {
                HStack {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Try Again") { Task { await load() } }
                }
            } else if let entries {
                if entries.isEmpty {
                    Text("Nothing in the library yet.").foregroundStyle(.secondary)
                } else {
                    filters(entries)
                    let shown = entries.filter {
                        (category == nil || Self.category($0) == category) && $0.matches(query)
                    }
                    let (reviewed, found) = Self.split(shown)
                    if shown.isEmpty { Text("No extension matches “\(query)”.").foregroundStyle(.secondary) }
                    ForEach(reviewed, id: \.id) { row($0) }
                    if !found.isEmpty { unreviewed(found) }
                }
            } else {
                LoadingLine(String(localized: "Loading…"))
            }
        } footer: {
            HStack {
                Text(
                    "Extensions people shared, each reviewed before it's added. Or any repository: kelp ext install owner/repo"
                )
                .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                Spacer()
                if let url = URL(string: "https://github.com/\(ExtensionFiles.libraryRepo)") {
                    Link("Share Yours on GitHub", destination: url).font(.ui(TextSize.caption))
                }
            }
        }
        .task { await load() }
    }

    /// The search, and the categories once the library has more than one.
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
    /// The library's categories in the order the menu lists them; an index from before them files everything as tools.
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

    /// The reviewed ones by name; those found on GitHub by their topic apart, fastest growing first.
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

    /// GitHub's repositories under the `kelp-extension` topic: nobody reviewed them, and the list says so first.
    private func unreviewed(_ found: [ExtensionLibrary.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("From GitHub · not reviewed").fontWeight(.semibold)
                Text("topic kelp-extension, fastest growing first").font(.ui(TextSize.caption)).foregroundStyle(
                    .secondary)
            }
            Text("Nobody at Kelp has looked at these. Before installing, Kelp shows every command one runs.")
                .font(.ui(TextSize.caption)).foregroundStyle(Color.textOrange)
            ForEach(found, id: \.id) { row($0) }
        }
        .padding(.top, 8)
    }

    private func row(_ entry: ExtensionLibrary.Entry) -> some View {
        let have = registry.extensions.first { $0.id == entry.id && !$0.builtin }
        return HStack(alignment: .top, spacing: Metrics.gapWide) {
            Image(systemName: entry.icon ?? "puzzlepiece.extension").font(.symbol(Metrics.iconLarge)).foregroundStyle(
                .secondary
            ).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    Text(entry.version).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                    if let stars = entry.stars {
                        Text("★ \(stars)" + (entry.weekly.map { $0 > 0 ? " · +\($0) this week" : "" } ?? "")).font(
                            .ui(TextSize.caption).monospacedDigit()
                        )
                        .foregroundStyle(.secondary)
                    }
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
                // found by its topic: its branch may have moved
                Button(entry.reviewed == false ? "Update…" : "Update") { install(entry) }
            } else {
                Text("Already installed").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
            // Where the daemon finds the tools they need; not said when it can't tell.
            if let found = await app.quiet(ProcessWhich(commands: Array(Set(all.flatMap { $0.requires ?? [] })))) {
                missing = Dictionary(
                    uniqueKeysWithValues: all.compactMap { entry in
                        (entry.requires ?? []).first { found[$0] == nil }.map { (entry.id, $0) }
                    })
            }
            entries = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            self.error = String(localized: "Couldn't load the library: \(AppModel.message(error))")
        }
    }
}
