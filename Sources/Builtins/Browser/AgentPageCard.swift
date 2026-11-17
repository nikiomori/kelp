// An agent's card: the page it drives (`AgentPages`), as a picture with what it did there last.
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The page an agent (or one of its subagents) acted on last: a picture, taken while the card is up (when it opens and
/// after each action, never otherwise), its last steps, the errors it reported, and Show Page / Take Over. Several
/// pages: small pictures of the others under it, a click shows that one.
struct AgentPageCard: View {
    let app: AppModel, session: String
    /// Puts the card away (a page shown takes its place).
    let close: @MainActor () -> Void
    @State private var picked: String?
    @State private var pictures: [String: NSImage] = [:]

    var body: some View {
        let pages = AgentPages.of(app).of(session: session)
        if let shown = pages.first(where: { $0.id == picked }) ?? Self.latest(pages) {
            VStack(alignment: .leading, spacing: 6) {
                head(shown.page)
                frame(shown.id, height: 150)
                    .task(id: shown.page.steps.last?.at) { await take(shown.id) }
                if pages.count > 1 { others(pages, shown: shown.id) }
                ForEach(Array(shown.page.steps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 6) {
                        Text(step.text).font(.ui(TextSize.caption)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(shortAgo(step.at)).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                if let error = shown.page.lastError {
                    Text(
                        shown.page.errors == 1
                            ? String(localized: "1 error · \(error)")
                            : String(localized: "\(shown.page.errors) errors · last: \(error)")
                    )
                    .font(.ui(TextSize.caption)).foregroundStyle(Color(nsColor: .textRed)).lineLimit(2)
                }
                buttons(shown)
            }
        }
    }

    /// The page acted on last.
    static func latest(_ pages: [(id: String, page: AgentPages.Page)]) -> (id: String, page: AgentPages.Page)? {
        pages.max { ($0.page.steps.last?.at ?? .distantPast) < ($1.page.steps.last?.at ?? .distantPast) }
    }

    private func head(_ page: AgentPages.Page) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(page.title.isEmpty ? URL(string: page.url)?.host ?? page.url : page.title)
                    .font(.ui(TextSize.row, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.place(page.url)).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            if let line = holder(page) {
                Text(line).font(.ui(TextSize.caption)).foregroundStyle(Color.accentColor).lineLimit(2)
            } else if let subagent = page.subagent {
                Text(subagentTitle(subagent)).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func holder(_ page: AgentPages.Page) -> String? {
        switch page.holder {
        case .agent: nil
        case .user: String(localized: "You have the page: the agent waits until you hand it back")
        case .asked(let question): String(localized: "Asks you: \(question)")
        }
    }

    private func subagentTitle(_ id: String) -> String {
        app.session(session)?.runningSubagents.first { $0.id == id }?.title ?? String(localized: "Subagent")
    }

    /// `localhost:3000/checkout`.
    static func place(_ url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        return host + (parsed.port.map { ":\($0)" } ?? "") + (parsed.path == "/" ? "" : parsed.path)
    }

    @ViewBuilder private func frame(_ id: String, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusXS)
        Group {
            if let image = pictures[id] {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: height, alignment: .top).clipped()
            } else {
                Color(nsColor: .fillRest).frame(maxWidth: .infinity).frame(height: height)
            }
        }
        .frame(height: height)
        .clipShape(shape)
        .overlay(shape.stroke(Color(nsColor: .separatorColor)))
        .contentShape(shape)
        .onTapGesture { show(id) }
    }

    private func others(_ pages: [(id: String, page: AgentPages.Page)], shown: String) -> some View {
        HStack(spacing: 6) {
            ForEach(pages.filter { $0.id != shown }, id: \.id) { other in
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        picked = other.id
                    } label: {
                        thumbnail(other.id)
                    }
                    .buttonStyle(.plain)
                    .task(id: other.page.steps.last?.at) { await take(other.id) }
                    Text(
                        other.page.subagent.map(subagentTitle) ?? app.session(session).map(
                            app.catalog.displayName) ?? ""
                    )
                    .font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 84)
            }
        }
    }

    @ViewBuilder private func thumbnail(_ id: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusXS)
        Group {
            if let image = pictures[id] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color(nsColor: .fillRest)
            }
        }
        .frame(width: 84, height: 52, alignment: .top).clipShape(shape)
        .overlay(shape.stroke(Color(nsColor: .separatorColor)))
    }

    private func buttons(_ shown: (id: String, page: AgentPages.Page)) -> some View {
        HStack(spacing: 6) {
            Button(String(localized: "Show Page")) { show(shown.id) }.controlSize(.small)
            Button(shown.page.holder == .agent ? String(localized: "Take Over") : String(localized: "Hand Back")) {
                AgentPages.of(app).handle(shown.id)?.hold(shown.page.holder == .agent)
            }
            .controlSize(.small)
        }
    }

    private func show(_ id: String) {
        AgentPages.of(app).show(id)
        close()
    }

    private func take(_ id: String) async {
        if let image = await AgentPages.of(app).handle(id)?.picture() { pictures[id] = image }
    }
}
