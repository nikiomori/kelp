import Core
import Foundation

/// A folded group of the Skills & MCP panel: one kind's items from one source, the servers that wait for a sign-in,
/// all the plugins, or one plugin's skills.
struct AddonGroup: Hashable {
    var kind: Addon.Kind
    /// nil: the servers waiting for a sign-in, whatever brought them.
    var source: Addon.Source?
    /// One plugin's skills: a plugin goes on and off whole, so its line has the switch. It sits in the Plugins group.
    var plugin: String?

    /// What `addons.set` takes for the whole group; nil when its items switch one by one.
    var key: String? { plugin.map { "plugin:\($0)" } }

    var title: String {
        if let plugin { return plugin }
        guard let source else { return String(localized: "Not signed in") }
        return switch source {
        case .kelp: String(localized: "Kelp")
        case .yours: String(localized: "Yours")
        case .project: String(localized: "This project")
        case .account where kind == .server: String(localized: "claude.ai connectors")
        case .account: String(localized: "claude.ai")
        case .plugin: String(localized: "Plugins")
        case .agent: String(localized: "Built in")
        }
    }
    /// The person's own skills and the project's show; the many others wait for a click.
    var openAtFirst: Bool { kind == .skill && plugin == nil && (source == .yours || source == .project) }
}

/// How the list is shown: the order inside groups, whether what's off shows, and the filter's text.
struct AddonView: Equatable {
    var byName = false
    var showOff = true
    var filter = ""
}

/// One line of the panel's list.
enum AddonLine: Equatable {
    enum Section: Equatable { case needsLook, servers, skills, instructions }
    case section(Section, count: Int)
    /// `tokens`: what its items weigh together; nil when none of theirs is known.
    case group(AddonGroup, count: Int, tokens: Int?, open: Bool)
    /// `depth`: 0 on its own, 1 under a group's line, 2 under a plugin's.
    case item(Addon, depth: Int)
    /// In Needs a Look: its name over what's wrong.
    case problem(Addon)
    /// In Needs a Look: the servers that wait for a sign-in and are on, as one line.
    case unsigned([Addon])
}

/// What the panel lists, in its order, without AppKit: what needs a look, the servers (the person's and the
/// project's one by one, the rest folded), the skills by who brought them, the instruction files.
enum AddonGroups {
    static let skillSources: [Addon.Source] = [.project, .yours, .kelp, .plugin, .account, .agent]
    static let folded: [Addon.Source] = [.account, .plugin, .agent]

    /// `toggled`: the groups the person folded or unfolded, against `openAtFirst` (against open while filtering).
    static func lines(_ items: [Addon], toggled: Set<AddonGroup>, view: AddonView = .init()) -> [AddonLine] {
        let lister = Lister(items: shown(items, view), toggled: toggled, view: view)
        return lister.needsLook() + lister.servers() + lister.skills() + lister.instructions()
    }

    /// What the view lets through: what's off only when it shows, and only names the filter matches.
    static func shown(_ items: [Addon], _ view: AddonView) -> [Addon] {
        let filter = view.filter.trimmingCharacters(in: .whitespaces)
        return items.filter { addon in
            (view.showOff || !addon.off) && (filter.isEmpty || addon.name.localizedCaseInsensitiveContains(filter))
        }
    }

    /// The heaviest first, those of unknown weight last, then by name.
    static func byWeight(_ a: Addon, _ b: Addon) -> Bool {
        switch (a.tokens, b.tokens) {
        case (let x?, let y?) where x != y: x > y
        case (.some, nil): true
        case (nil, .some): false
        default: byName(a, b)
        }
    }
    static func byName(_ a: Addon, _ b: Addon) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }

    /// What a list weighs together; nil when none of it is known.
    static func sum(_ items: [Addon]) -> Int? {
        let known = items.compactMap(\.tokens)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// Whether a group's switch is off: its plugin is named off, or what loaded of it is.
    static func isOff(_ g: AddonGroup, _ items: [Addon]) -> Bool {
        guard let key = g.key else { return false }
        return items.contains { $0.key == key && $0.off }
    }

    /// A change that waits for a restart: off but loaded in this chat, or on again and not loaded.
    static func waits(_ addon: Addon) -> Bool {
        guard addon.key != nil, let loaded = addon.loaded, addon.problem == nil else { return false }
        return addon.off == loaded
    }

    /// The servers that wait for a sign-in and are on: they offer nothing and still cost their tokens.
    static func unsigned(_ items: [Addon]) -> [Addon] {
        items.filter { $0.kind == .server && $0.signIn && !$0.off && $0.problem == nil && $0.key != nil }
    }
}

/// The lines of one listing: the items the view lets through, the groups folded by hand, the view's order.
private struct Lister {
    let items: [Addon], toggled: Set<AddonGroup>, view: AddonView
    private var filtering: Bool { !view.filter.trimmingCharacters(in: .whitespaces).isEmpty }

    func needsLook() -> [AddonLine] {
        let problems = items.filter { $0.problem != nil }, unsigned = AddonGroups.unsigned(items)
        let lines = problems.map(AddonLine.problem) + (unsigned.isEmpty ? [] : [.unsigned(unsigned)])
        return lines.isEmpty ? [] : [.section(.needsLook, count: lines.count)] + lines
    }

    func servers() -> [AddonLine] {
        let servers = items.filter { $0.kind == .server }
        guard !servers.isEmpty else { return [] }
        let ready = servers.filter { !$0.signIn }
        var out: [AddonLine] = [.section(.servers, count: servers.count)]
        out += sorted(ready.filter { !AddonGroups.folded.contains($0.source) }).map { .item($0, depth: 0) }
        for source in AddonGroups.folded {
            out += group(.init(kind: .server, source: source), ready.filter { $0.source == source })
        }
        return out + group(.init(kind: .server, source: nil), servers.filter(\.signIn))
    }

    func skills() -> [AddonLine] {
        let skills = items.filter { $0.kind == .skill }, plugins = plugins()
        guard !skills.isEmpty || !plugins.isEmpty else { return [] }
        var out: [AddonLine] = [.section(.skills, count: skills.count)]
        for source in AddonGroups.skillSources {
            out +=
                source == .plugin
                ? plugins : group(.init(kind: .skill, source: source), skills.filter { $0.source == source })
        }
        return out
    }

    func instructions() -> [AddonLine] {
        let files = items.filter { $0.kind == .instructions }
        guard !files.isEmpty else { return [] }
        return [.section(.instructions, count: files.count)] + sorted(files).map { .item($0, depth: 0) }
    }

    /// One Plugins group; in it a line per plugin with its switch, each unfolding to its skills. One that's off
    /// (nothing of it loaded) is a line with nothing to unfold.
    private func plugins() -> [AddonLine] {
        let skills = items.filter { $0.kind == .skill && $0.source == .plugin }
        let names = Set(skills.compactMap(\.origin)).union(items.filter { $0.kind == .plugin }.map(\.name))
        guard !names.isEmpty else { return [] }
        let each = names.map { name in (name: name, skills: skills.filter { $0.origin == name }) }
        let ordered = each.sorted { a, b in
            let x = AddonGroups.sum(a.skills) ?? -1, y = AddonGroups.sum(b.skills) ?? -1
            return view.byName || x == y ? a.name.localizedStandardCompare(b.name) == .orderedAscending : x > y
        }
        let outer = AddonGroup(kind: .skill, source: .plugin), open = isOpen(outer)
        let head = AddonLine.group(outer, count: names.count, tokens: AddonGroups.sum(skills), open: open)
        guard open else { return [head] }
        return [head]
            + ordered.flatMap { plugin -> [AddonLine] in
                let g = AddonGroup(kind: .skill, source: .plugin, plugin: plugin.name)
                return plugin.skills.isEmpty
                    ? [.group(g, count: 0, tokens: nil, open: false)] : group(g, plugin.skills, depth: 2)
            }
    }

    private func group(_ g: AddonGroup, _ list: [Addon], depth: Int = 1) -> [AddonLine] {
        guard !list.isEmpty else { return [] }
        let open = isOpen(g)
        return [.group(g, count: list.count, tokens: AddonGroups.sum(list), open: open)]
            + (open ? sorted(list).map { .item($0, depth: depth) } : [])
    }

    /// While filtering every group with a match is open, and a click folds it; else as it starts, or as clicked.
    private func isOpen(_ g: AddonGroup) -> Bool { (filtering || g.openAtFirst) != toggled.contains(g) }

    private func sorted(_ list: [Addon]) -> [Addon] {
        list.sorted(by: view.byName ? AddonGroups.byName : AddonGroups.byWeight)
    }
}
