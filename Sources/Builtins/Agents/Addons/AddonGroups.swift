import Core
import Foundation

/// A group of rows in the Skills & MCP panel that folds. It holds the items of one kind from one source, the servers
/// that wait for a sign-in, all the plugins, the skills of one plugin, or the items that only another agent gets.
struct AddonGroup: Hashable {
    var kind: Addon.Kind
    /// nil for the group of servers that wait for a sign-in, whatever source brought them.
    var source: Addon.Source?
    /// The plugin whose skills this group holds. A plugin goes on and off as a whole, so the switch is on the plugin's
    /// line, which sits in the Plugins group.
    var plugin: String?
    /// The id of the other agent that alone gets this group's items, so they never reach the chat on screen. The
    /// group's line shows that agent's name from the catalog.
    var agent: String?

    /// The key `addons.set` takes to switch the whole group; nil when the group's items switch one by one.
    var key: String? { plugin.map { "plugin:\($0)" } }

    var title: String {
        if let plugin { return plugin }
        if let agent { return agent }
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
    /// The groups of the person's own skills and of the project's skills start open. The other groups hold many
    /// items, so they start folded until clicked.
    var openAtFirst: Bool { kind == .skill && plugin == nil && (source == .yours || source == .project) }
}

/// How the list is shown: the order inside groups, whether items that are off show, and the filter text.
struct AddonView: Equatable {
    var byName = false
    var showOff = true
    var filter = ""
}

/// One line of the panel's list.
enum AddonLine: Equatable {
    enum Section: Equatable { case needsLook, servers, skills, instructions, others }
    case section(Section, count: Int)
    /// `tokens` is the total weight of the group's items; nil when no item's weight is known.
    case group(AddonGroup, count: Int, tokens: Int?, open: Bool)
    /// `depth` is 0 for an item on its own, 1 under a group's line, and 2 under a plugin's line.
    case item(Addon, depth: Int)
    /// A row in Needs a Look that shows the item's name above what is wrong with it.
    case problem(Addon)
    /// One row in Needs a Look for all the servers that are on and wait for a sign-in.
    case unsigned([Addon])
    /// One row in Needs a Look for the project's instruction files that need a look, with a Tidy Up button. After a
    /// Tidy Up, the row shows what it did instead, to review or undo.
    case instructions([Addon], Tidied?)

    /// The line's name across a reload: the same item stays the same line while its switch or weight changes.
    var key: String {
        switch self {
        case .section(let section, _): "section \(section)"
        case .group(let group, _, _, _): "group \(group)"
        case .item(let addon, let depth): "item \(addon.id) \(addon.source) \(depth)"
        case .problem(let addon): "problem \(addon.id) \(addon.source)"
        case .unsigned: "unsigned"
        case .instructions: "instructions"
        }
    }
}

/// Builds the panel's list in order, without AppKit. First comes what needs a look, then the servers (the person's
/// and the project's one by one, the rest folded), the skills grouped by who brought them, the instruction files, and,
/// folded at the end, what only other agents get.
enum AddonGroups {
    static let skillSources: [Addon.Source] = [.project, .yours, .kelp, .plugin, .account, .agent]
    static let folded: [Addon.Source] = [.account, .plugin, .agent]

    /// Returns the panel's lines. `toggled` holds the groups the person folded or unfolded, compared with
    /// `openAtFirst` (or with open, while filtering). `agent` is the agent of the chat on screen. Items that agent
    /// never gets move out of the other sections into Other Agents.
    static func lines(
        _ items: [Addon], toggled: Set<AddonGroup>, view: AddonView = .init(), tidied: Tidied? = nil,
        agent: String? = nil
    ) -> [AddonLine] {
        let all = shown(items, view)
        let lister = Lister(
            items: agent.map { a in all.filter { !elsewhere($0, a) } } ?? all, all: all, agent: agent,
            toggled: toggled, view: view, tidied: tidied)
        return lister.needsLook() + lister.servers() + lister.skills() + lister.instructions() + lister.others()
    }

    /// True when only other agents get the item, so chats with `agent` never do.
    static func elsewhere(_ addon: Addon, _ agent: String) -> Bool {
        !addon.agents.isEmpty && !addon.agents.contains(agent)
    }

    /// The group line a row sits under; nil for a row on its own.
    static func parent(of row: Int, in lines: [AddonLine]) -> AddonGroup? {
        guard lines.indices.contains(row), case .item(_, let depth) = lines[row], depth > 0 else { return nil }
        for line in lines[..<row].reversed() {
            if case .group(let group, _, _, _) = line, depth == 1 || group.plugin != nil { return group }
        }
        return nil
    }

    /// Returns the items the view lets through. Items that are off pass only when the view shows them, and only names
    /// that match the filter pass.
    static func shown(_ items: [Addon], _ view: AddonView) -> [Addon] {
        let filter = view.filter.trimmingCharacters(in: .whitespaces)
        return items.filter { addon in
            (view.showOff || !addon.off) && (filter.isEmpty || addon.name.localizedCaseInsensitiveContains(filter))
        }
    }

    /// Sorts the heaviest item first and items of unknown weight last. Items of equal weight sort by name.
    static func byWeight(_ addon: Addon, _ other: Addon) -> Bool {
        switch (addon.tokens, other.tokens) {
        case (let x?, let y?) where x != y: x > y
        case (.some, nil): true
        case (nil, .some): false
        default: byName(addon, other)
        }
    }
    static func byName(_ addon: Addon, _ other: Addon) -> Bool {
        addon.name.localizedStandardCompare(other.name) == .orderedAscending
    }

    /// Returns the total weight of the items; nil when no item's weight is known.
    static func sum(_ items: [Addon]) -> Int? {
        let known = items.compactMap(\.tokens)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// True when the group's switch is off, which is when an item with the group's key is off: the plugin's own entry,
    /// or one of its skills that loaded.
    static func isOff(_ addonGroup: AddonGroup, _ items: [Addon]) -> Bool {
        guard let key = addonGroup.key else { return false }
        return items.contains { $0.key == key && $0.off }
    }

    /// True when a switch change waits for a restart. The item is off but still loaded in this chat, or it is on again
    /// but not loaded yet.
    static func waits(_ addon: Addon) -> Bool {
        guard addon.key != nil, let loaded = addon.loaded, addon.problem == nil else { return false }
        return addon.off == loaded
    }

    /// Returns the servers that are on and wait for a sign-in. They offer nothing yet still cost their tokens.
    static func unsigned(_ items: [Addon]) -> [Addon] {
        items.filter { $0.kind == .server && $0.signIn && !$0.off && $0.problem == nil && $0.key != nil }
    }
}

/// Builds the lines of one listing from the items the view lets through, the groups the person folded by hand, and
/// the order the view asks for.
private struct Lister {
    /// `items` is what the chat's agent gets. `all` also holds what only other agents get.
    let items: [Addon], all: [Addon], agent: String?, toggled: Set<AddonGroup>, view: AddonView
    var tidied: Tidied?
    private var filtering: Bool { !view.filter.trimmingCharacters(in: .whitespaces).isEmpty }

    func needsLook() -> [AddonLine] {
        // An item that is off for the project has been dealt with, so it stays grey in its own section and leaves
        // Needs a Look. A problem with another agent's item is still the project's problem, so it shows here too.
        let items = all
        let problems = items.filter { $0.problem != nil && !$0.off }, unsigned = AddonGroups.unsigned(items)
        let tidy = AddonGroups.tidied(items).filter { $0.check?.needsLook == true }
        let lines =
            problems.map(AddonLine.problem) + (unsigned.isEmpty ? [] : [.unsigned(unsigned)])
            + (tidy.isEmpty && tidied == nil ? [] : [.instructions(tidy, tidied)])
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

    /// Lists what only other agents get, in one folded group per agent. An item goes under the first agent that gets
    /// it.
    func others() -> [AddonLine] {
        guard let agent else { return [] }
        let list = all.filter { AddonGroups.elsewhere($0, agent) }
        guard !list.isEmpty else { return [] }
        var seen = Set<String>()
        let agents = list.compactMap(\.agents.first).filter { seen.insert($0).inserted }
        return [.section(.others, count: list.count)]
            + agents.flatMap { id in
                group(.init(kind: .skill, source: nil, agent: id), list.filter { $0.agents.first == id })
            }
    }

    /// Builds the one Plugins group. It holds a line per plugin with the plugin's switch, and each line unfolds to the
    /// plugin's skills. A plugin that is off has no skills loaded, so its line has nothing to unfold.
    private func plugins() -> [AddonLine] {
        let skills = items.filter { $0.kind == .skill && $0.source == .plugin }
        let names = Set(skills.compactMap(\.origin)).union(items.filter { $0.kind == .plugin }.map(\.name))
        guard !names.isEmpty else { return [] }
        let each = names.map { name in (name: name, skills: skills.filter { $0.origin == name }) }
        let ordered = each.sorted { left, right in
            let x = AddonGroups.sum(left.skills) ?? -1, y = AddonGroups.sum(right.skills) ?? -1
            return view.byName || x == y ? left.name.localizedStandardCompare(right.name) == .orderedAscending : x > y
        }
        let outer = AddonGroup(kind: .skill, source: .plugin), open = isOpen(outer)
        let head = AddonLine.group(outer, count: names.count, tokens: AddonGroups.sum(skills), open: open)
        guard open else { return [head] }
        return [head]
            + ordered.flatMap { plugin -> [AddonLine] in
                let made = AddonGroup(kind: .skill, source: .plugin, plugin: plugin.name)
                return plugin.skills.isEmpty
                    ? [.group(made, count: 0, tokens: nil, open: false)] : group(made, plugin.skills, depth: 2)
            }
    }

    private func group(_ addonGroup: AddonGroup, _ list: [Addon], depth: Int = 1) -> [AddonLine] {
        guard !list.isEmpty else { return [] }
        let open = isOpen(addonGroup)
        return [.group(addonGroup, count: list.count, tokens: AddonGroups.sum(list), open: open)]
            + (open ? sorted(list).map { .item($0, depth: depth) } : [])
    }

    /// While filtering, every group with a match is open and a click folds it. Otherwise a group is as it starts, or
    /// the other way when the person clicked it.
    private func isOpen(_ addonGroup: AddonGroup) -> Bool {
        (filtering || addonGroup.openAtFirst) != toggled.contains(addonGroup)
    }

    private func sorted(_ list: [Addon]) -> [Addon] {
        list.sorted(by: view.byName ? AddonGroups.byName : AddonGroups.byWeight)
    }
}
