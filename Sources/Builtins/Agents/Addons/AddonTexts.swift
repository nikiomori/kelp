import Core
import DesignKit
import Foundation

/// What a chat's start is made of, by the four parts the panel's bar shows.
enum AddonPart: CaseIterable, Equatable {
    case instructions, plugins, servers, other

    var title: String {
        switch self {
        case .instructions: String(localized: "Instructions")
        case .plugins: String(localized: "Plugins")
        case .servers: String(localized: "Servers")
        case .other: String(localized: "Other")
        }
    }

    init(_ addon: Addon) {
        self =
            switch addon.kind {
            case .instructions: .instructions
            case .server: .servers
            case .plugin: .plugins
            case .skill: addon.source == .plugin ? .plugins : .other
            }
    }
}

/// Where a row comes from, as the mark on its right and a line of its tip.
extension Addon.Source {
    var symbol: String {
        switch self {
        case .project: "folder"
        case .yours: "laptopcomputer"
        case .account: "cloud"
        case .plugin: "puzzlepiece.extension"
        case .agent: "cube"
        case .kelp: "leaf"
        }
    }
    var words: String {
        switch self {
        case .project: String(localized: "In this project")
        case .yours: String(localized: "On this Mac, outside the project")
        case .account: String(localized: "From the agent’s account")
        case .plugin: String(localized: "From a plugin")
        case .agent: String(localized: "Built into the agent")
        case .kelp: String(localized: "Kelp’s own")
        }
    }
}

/// The panel's words and numbers, without AppKit.
extension AddonGroups {
    struct Share: Equatable {
        var part: AddonPart, tokens: Int
    }

    /// What the known weight is made of, the biggest first; parts that weigh nothing left out.
    static func weight(_ items: [Addon]) -> [Share] {
        var sums: [AddonPart: Int] = [:]
        for addon in items { if let tokens = addon.tokens { sums[AddonPart(addon), default: 0] += tokens } }
        return AddonPart.allCases.compactMap { part in
            sums[part].flatMap { $0 > 0 ? Share(part: part, tokens: $0) : nil }
        }
        .sorted { $0.tokens > $1.tokens }
    }

    /// "38.4k tokens before the first word" when the list is a chat's own record and weights are known (the files
    /// alone don't know them); else "152 skills · 45 servers".
    static func headline(_ items: [Addon], chat: Bool) -> String {
        if chat, let total = sum(items).map(shortTokens) {
            return String(localized: "\(total) tokens before the first word")
        }
        let skills = items.count { $0.kind == .skill }, servers = items.count { $0.kind == .server }
        return [String(localized: "\(skills) skills"), String(localized: "\(servers) servers")].joined(separator: " · ")
    }

    /// A group's line: "7 · 0.5k", the count alone while its weight is unknown.
    static func countAndTokens(_ count: Int, _ tokens: Int?) -> String {
        guard let tokens else { return count.formatted() }
        let tenths = max(1, (tokens + 50) / 100)
        return "\(count.formatted()) · " + (tenths >= 10 ? shortTokens(max(tokens, 1000)) : "0.\(tenths)k")
    }

    /// Needs a Look's line for the servers waiting for a sign-in: what it is, and what it costs.
    static func unsignedText(_ servers: [Addon]) -> (title: String, detail: String) {
        let title =
            servers.count == 1
            ? String(localized: "1 server isn’t signed in")
            : String(localized: "\(servers.count) servers aren’t signed in")
        guard let tokens = sum(servers) else { return (title, String(localized: "They do nothing until signed in")) }
        return (title, String(localized: "Idle, \(shortTokens(tokens)) tokens each chat"))
    }

    /// Its size against the fuller of its limits: "230 of 200 lines", "27.8 KB of 25 KB".
    static func size(_ check: InstructionCheck) -> String? {
        let byLines = check.maxLines.map { Double(check.lines) / Double($0) } ?? 0
        let byBytes = check.maxBytes.map { Double(check.bytes) / Double($0) } ?? 0
        if byBytes > byLines, let most = check.maxBytes {
            return String(localized: "\(bytes(check.bytes, file: true)) of \(bytes(most, file: true))")
        }
        return check.maxLines.map { String(localized: "\(check.lines) of \($0) lines") }
    }

    /// A row's tooltip: what it says about itself, where it is, its other copies.
    static func tip(_ addon: Addon, names: (String) -> String = { $0 }) -> String {
        var lines =
            [addon.about, addon.source.words, addon.origin] + addon.copies.map { String(localized: "Also in \($0)") }
        if let check = addon.check {
            lines += findings(check, name: addon.name)
            lines.append(size(check) ?? String(localized: "\(check.lines) lines"))
            if let first = check.dead.first {
                let more = check.dead.count - 1
                lines.append(
                    more == 0
                        ? String(localized: "Gone: \(first)") : String(localized: "Gone: \(first) and \(more) more"))
            }
        }
        if !addon.fixed.isEmpty {
            let who = addon.fixed.map(names).joined(separator: ", ")
            lines.append(String(localized: "Always on in \(who): no switch for one chat there"))
        }
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    /// How many of a row's extras fit, first first: each takes its width of `room` while there's that much left.
    static func fitting(_ widths: [CGFloat], in room: CGFloat) -> Int {
        var left = room, count = 0
        for width in widths {
            guard width <= left else { break }
            left -= width
            count += 1
        }
        return count
    }

    /// When a chat read what it holds, beside the weight: "loaded 14:20" today, "loaded Nov 6" before.
    static func loaded(_ date: Date, now: Date = .now) -> String {
        let when =
            Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "loaded \(when)")
    }

    /// Under the list while the chat is behind: what it still holds though it's gone, or that changes wait.
    static func footNote(gone: [String]) -> String {
        guard let first = gone.first else { return String(localized: "Changes reach new chats.") }
        return gone.count == 1
            ? String(localized: "This chat still has \(first), removed since.")
            : String(localized: "This chat still has \(first) and \(gone.count - 1) more, removed since.")
    }

    /// The folders skills are kept in: the person's two, and the project's two that hold one of the listed skills.
    static func skillFolders(home: String, project: String?, items: [Addon]) -> [String] {
        let own = [".agents/skills", ".claude/skills"]
        let projects = project.map { root in own.map { root + "/" + $0 } } ?? []
        return own.map { home + "/" + $0 }
            + projects.filter { folder in items.contains { $0.path?.hasPrefix(folder + "/") == true } }
    }

    /// The id a plugin was installed under ("sales@synced"), from any of its items that knows it.
    static func pluginId(_ name: String, _ items: [Addon]) -> String? {
        items.first { $0.plugin != nil && ($0.kind == .plugin ? $0.name : $0.origin) == name }?.plugin
    }

    /// A plugin's folder, from one of its skills' SKILL.md (`<plugin>/skills/<skill>/SKILL.md`).
    static func pluginFolder(_ name: String, _ items: [Addon]) -> String? {
        guard let path = items.first(where: { $0.source == .plugin && $0.origin == name && $0.path != nil })?.path
        else { return nil }
        return (0..<3).reduce(path) { folder, _ in (folder as NSString).deletingLastPathComponent }
    }

    /// The name a server has in its file (its key's), which the agents' own commands take.
    static func serverName(_ addon: Addon) -> String {
        guard let key = addon.key, key.hasPrefix("server:") else { return addon.name }
        return String(key.dropFirst("server:".count))
    }
}
