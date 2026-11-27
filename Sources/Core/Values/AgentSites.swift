import Foundation

/// The sites where the user lets agents use their login from Kelp's browser (`SettingKeys.agentSites`), each with the
/// chat it was first allowed for and when. Only the user changes the list (`SettingsSet.usersOnly`): kelpd adds a site
/// when the user answers Allow on an agent's row, and Settings › Browser or a page's Stop takes it away.
public enum AgentSites {
    public struct Entry: Equatable, Sendable {
        public let site: String, chat: String, at: Date
    }

    public static func entries(_ list: [JSONValue]) -> [Entry] {
        list.compactMap { item in
            guard let site = item["site"]?.string, !site.isEmpty else { return nil }
            let at = item["at"]?.number.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            return Entry(site: site, chat: item["chat"]?.string ?? "", at: at)
        }
    }

    /// The site of an address an agent opens, as far as a login reaches (`PageOrigin`): `x.com` for
    /// `https://mobile.x.com/home`, without the scheme. An address without a scheme is a site's (`x.com/home`). nil for
    /// anything but http and https.
    public static func site(of address: String) -> String? {
        let url = URL(string: address.contains("://") ? address : "https://" + address)
        guard ["http", "https"].contains(url?.scheme?.lowercased()), let origin = PageOrigin.of(url) else { return nil }
        return origin.components(separatedBy: "://").last
    }

    /// The site in `entries` that covers `host`: the site itself or one of its subdomains (`mobile.x.com` for `x.com`).
    public static func allowed(_ host: String, in entries: [Entry]) -> String? {
        entries.first { covers($0.site, host) }?.site
    }

    /// Whether `site` covers `host`: it is the site or one of its subdomains.
    public static func covers(_ site: String, _ host: String) -> Bool { host == site || host.hasSuffix("." + site) }

    /// The list with `site` added for `chat`, now. A site already there stays as it was.
    public static func adding(_ site: String, chat: String, to list: [JSONValue], at: Date = Date()) -> [JSONValue] {
        guard !entries(list).contains(where: { $0.site == site }) else { return list }
        let when = JSONValue.int(Int(at.timeIntervalSince1970))
        return list + [.object(["site": .string(site), "chat": .string(chat), "at": when])]
    }

    /// What an agent's row asks before the agent gets the user's login on `site` (kelpd's `BrowserRelay.login`). It
    /// starts with "Allow", so Kelp offers Allow and Deny wherever it shows (`Session.asksPermission`): the card over
    /// the agent's terminal (`asksLogin`), the Dock's strip, a notification, the phone. It says what Allow gives: the
    /// site is kept for every agent in every project (`browser.agentSites`), not this chat alone.
    public static func question(agent: String, site: String) -> String {
        "Allow \(agent) and every other agent, in every project, to use your login on \(site)?"
    }

    /// What a login question's answer names (`SessionChoose.run`), so it answers that question alone: never another
    /// question worded like it, such as a shell command's permission ("Allow <command>?"), whose words the agent chose.
    public static func run(_ site: String) -> String { "login/" + site }

    /// The site a login question asks about, read back from its words.
    public static func asked(_ question: String) -> String? {
        guard asksLogin(question), let at = question.range(of: " to use your login on ", options: .backwards) else {
            return nil
        }
        let site = question[at.upperBound...].dropLast()
        return site.isEmpty ? nil : String(site)
    }

    public static func asksLogin(_ question: String) -> Bool {
        question.hasPrefix("Allow ") && question.hasSuffix("?") && question.contains(" to use your login on ")
    }

    public static func removing(_ site: String, from list: [JSONValue]) -> [JSONValue] {
        list.filter { $0["site"]?.string != site }
    }
}
