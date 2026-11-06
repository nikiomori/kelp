import AppKit
import Core

/// What a folded project or group says of the chats inside it, on its second line: what one of them asks (and in which
/// group), else how many there are and the one that moved last. Follows Settings › Appearance › Second Line: Never, none.
struct FoldedLine {
    var place: String?
    var prefix: (String, NSColor)?
    var text: String

    /// The chats under `n`, each with the group it's in (nil: the project's own screen).
    @MainActor static func chats(under n: SidebarController.Node, _ app: AppModel) -> [(session: Session, place: String?)] {
        n.children.flatMap { c -> [(session: Session, place: String?)] in
            switch c.kind {
            case .agent(let id): return app.session(id).map { [($0, nil)] } ?? []
            case .workspace(let w):
                let place = app.worktree(w)?.displayName
                return c.children.compactMap { if case .agent(let id) = $0.kind { app.session(id).map { ($0, place) } } else { nil } }
            case .project, .host, .parked: return []
            }
        }
    }

    @MainActor static func of(_ n: SidebarController.Node, _ app: AppModel) -> FoldedLine? {
        let all = chats(under: n, app), mode = app.settings.string("workbench.sidebar.agentDetail") ?? "needsYou"
        guard mode != "never", !all.isEmpty else { return nil }
        // A group's own row needs no "group ›": it's the group.
        let named = { (place: String?) -> String? in if case .project = n.kind { place } else { nil } }
        if let (s, place) = all.first(where: { SidebarCell.askLine($0.session, mode: "needsYou")?.prefix != nil }),
            let line = SidebarCell.askLine(s, mode: "needsYou")
        {
            return FoldedLine(place: named(place), prefix: line.prefix, text: line.text)
        }
        guard let last = all.map(\.session).max(by: { ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt) }) else { return nil }
        let name = app.catalog.displayName(last)
        return FoldedLine(text: all.count == 1 ? name : String(localized: "\(all.count) chats") + " · " + name)
    }

    /// The agents in it, the most used first, at most three.
    @MainActor static func agents(under n: SidebarController.Node, _ app: AppModel) -> [String] {
        let ids = chats(under: n, app).compactMap(\.session.agent).filter { $0 != "custom" && $0 != "shell" }  // a shell isn't an agent
        let counts = Dictionary(ids.map { ($0, 1) }, uniquingKeysWith: +)
        return Array(counts.keys.sorted { (counts[$0] ?? 0, $1) > (counts[$1] ?? 0, $0) }.prefix(3))
    }
}
