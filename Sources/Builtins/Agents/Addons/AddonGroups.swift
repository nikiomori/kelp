import Core
import Foundation

/// A folded group of the Skills & MCP panel: one kind's items from one source, or the servers that wait for a sign-in.
struct AddonGroup: Hashable {
    var kind: Addon.Kind
    /// nil: the servers waiting for a sign-in, whatever brought them.
    var source: Addon.Source?
    /// One plugin's skills: a plugin goes on and off whole, so each is a group with the switch on its line.
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
    var openAtFirst: Bool { kind == .skill && (source == .yours || source == .project) }
}

/// One line of the panel's list.
enum AddonLine: Equatable {
    enum Section: Equatable { case needsLook, servers, skills, instructions }
    case section(Section, count: Int)
    case group(AddonGroup, count: Int, open: Bool)
    /// `nested`: under a group's line.
    case item(Addon, nested: Bool)
    /// In Needs a Look: its name over what's wrong.
    case problem(Addon)
}

/// What the panel lists, in its order, without AppKit: what needs a look, the servers (the person's and the
/// project's one by one, the rest folded), the skills by who brought them, the instruction files.
enum AddonGroups {
    static let skillSources: [Addon.Source] = [.kelp, .yours, .project, .account, .plugin, .agent]
    static let folded: [Addon.Source] = [.account, .plugin, .agent]

    /// `toggled`: the groups the person folded or unfolded, against `openAtFirst`.
    static func lines(_ items: [Addon], toggled: Set<AddonGroup>) -> [AddonLine] {
        var out: [AddonLine] = []
        let problems = items.filter { $0.problem != nil }
        if !problems.isEmpty { out += [.section(.needsLook, count: problems.count)] + problems.map(AddonLine.problem) }
        let servers = items.filter { $0.kind == .server }
        if !servers.isEmpty {
            out.append(.section(.servers, count: servers.count))
            let ready = servers.filter { !$0.signIn }
            out += ready.filter { !folded.contains($0.source) }.map { .item($0, nested: false) }
            for source in folded {
                out += group(.init(kind: .server, source: source), ready.filter { $0.source == source }, toggled)
            }
            out += group(.init(kind: .server, source: nil), servers.filter(\.signIn), toggled)
        }
        let skills = items.filter { $0.kind == .skill }
        if !skills.isEmpty {
            out.append(.section(.skills, count: skills.count))
            for source in skillSources where source != .plugin {
                out += group(.init(kind: .skill, source: source), skills.filter { $0.source == source }, toggled)
            }
        }
        out += plugins(items, toggled)
        let files = items.filter { $0.kind == .instructions }
        if !files.isEmpty {
            out += [.section(.instructions, count: files.count)] + files.map { .item($0, nested: false) }
        }
        return out
    }

    /// Each plugin's skills under its name, and the plugins that are off (nothing of theirs loaded) as a line each.
    private static func plugins(_ items: [Addon], _ toggled: Set<AddonGroup>) -> [AddonLine] {
        let skills = items.filter { $0.kind == .skill && $0.source == .plugin }
        let names = Set(skills.compactMap(\.origin)).union(items.filter { $0.kind == .plugin }.map(\.name)).sorted()
        return names.flatMap { name -> [AddonLine] in
            let g = AddonGroup(kind: .skill, source: .plugin, plugin: name)
            let own = skills.filter { $0.origin == name }
            return own.isEmpty ? [.group(g, count: 0, open: false)] : group(g, own, toggled)
        }
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

    private static func group(_ g: AddonGroup, _ items: [Addon], _ toggled: Set<AddonGroup>) -> [AddonLine] {
        guard !items.isEmpty else { return [] }
        let open = g.openAtFirst != toggled.contains(g)
        return [.group(g, count: items.count, open: open)] + (open ? items.map { .item($0, nested: true) } : [])
    }

    /// "152 skills · 45 servers · ~7.5k tokens at start"; the tokens only when some are known.
    /// `chat`: the list is a chat's own record, which knows what things weigh; the files alone don't.
    static func summary(_ items: [Addon], chat: Bool = true) -> String {
        let skills = items.count { $0.kind == .skill }, servers = items.count { $0.kind == .server }
        var parts = [String(localized: "\(skills) skills"), String(localized: "\(servers) servers")]
        let known = items.compactMap(\.tokens)
        if chat, !known.isEmpty { parts.append(String(localized: "~\(k(known.reduce(0, +))) tokens at start")) }
        return parts.joined(separator: " · ")
    }

    /// A row's tooltip: what it says about itself, where it is, its other copies.
    static func tip(_ addon: Addon, names: (String) -> String = { $0 }) -> String {
        var lines = [addon.about, addon.origin] + addon.copies.map { String(localized: "Also in \($0)") }
        if !addon.fixed.isEmpty {
            let who = addon.fixed.map(names).joined(separator: ", ")
            lines.append(String(localized: "Always on in \(who): no switch for one chat there"))
        }
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    static func tokens(_ n: Int) -> String { String(localized: "\(k(n)) tok") }

    /// 17_600 → "17.6k", 31_000 → "31k", 640 → "640": as the context card says it (ContextParts.k, internal to
    /// KelpKit).
    static func k(_ tokens: Int) -> String {
        guard tokens >= 1000 else { return "\(tokens)" }
        let tenths = (tokens + 50) / 100
        return tokens >= 100_000 || tenths % 10 == 0 ? "\((tokens + 500) / 1000)k" : "\(tenths / 10).\(tenths % 10)k"
    }
}
