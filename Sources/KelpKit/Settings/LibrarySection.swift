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
                .font(.ui(11)).foregroundStyle(.secondary)
                Spacer()
                if let url = URL(string: "https://github.com/\(IDE.libraryRepo)") {
                    Link("Share Yours on GitHub", destination: url).font(.ui(11))
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
    static func category(_ e: ExtensionLibrary.Entry) -> String {
        e.category.map { categories.contains($0) ? $0 : "tools" } ?? "tools"
    }
    static func title(_ c: String) -> String {
        switch c {
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
                Text("topic kelp-extension, fastest growing first").font(.ui(11)).foregroundStyle(.secondary)
            }
            Text("Nobody at Kelp has looked at these. Before installing, Kelp shows every command one runs.")
                .font(.ui(11)).foregroundStyle(Color.textOrange)
            ForEach(found, id: \.id) { row($0) }
        }
        .padding(.top, 8)
    }

    private func row(_ e: ExtensionLibrary.Entry) -> some View {
        let have = registry.extensions.first { $0.id == e.id && !$0.builtin }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: e.icon ?? "puzzlepiece.extension").font(.symbol(Metrics.iconLarge)).foregroundStyle(
                .secondary
            ).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.name).fontWeight(.medium)
                    Text(e.version).font(.ui(11)).foregroundStyle(.secondary)
                    if let stars = e.stars {
                        Text("★ \(stars)" + (e.weekly.map { $0 > 0 ? " · +\($0) this week" : "" } ?? "")).font(
                            .ui(11).monospacedDigit()
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                if let d = e.description, !d.isEmpty { Text(d).font(.ui(11)).foregroundStyle(.secondary) }
                if let m = missing[e.id] {
                    Text("Needs `\(m)` — not found on this Mac.").font(.ui(11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if installing == e.id {
                ProgressView().controlSize(.small)
            } else if have == nil {
                Button(e.reviewed == false ? "Install…" : "Install") { install(e) }
            } else if let s = have?.source, s != e.source || e.reviewed == false {   // found by its topic: its branch may have moved
                Button(e.reviewed == false ? "Update…" : "Update") { install(e) }
            } else {
                Text("Already installed").font(.ui(11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func install(_ e: ExtensionLibrary.Entry) {
        installing = e.id
        Task {
            _ = await registry.install(source: e.source, files: e.files)
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
                    uniqueKeysWithValues: all.compactMap { e in
                        (e.requires ?? []).first { found[$0] == nil }.map { (e.id, $0) }
                    })
            }
            entries = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            self.error = String(localized: "Couldn't load the library: \(AppModel.message(error))")
        }
    }
}
