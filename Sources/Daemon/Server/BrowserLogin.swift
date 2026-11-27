import Agents
import Core
import Foundation

/// Whether an agent's `kelp browser open` gets the user's login from Kelp's browser. kelpd decides it, never the
/// caller: the app opens a page with the user's cookies only for the `yourLogin` field set here.
extension BrowserRelay {
    /// Returns the site of an `open` that gets the user's login, or nil for a page of the agent's own. A site the user
    /// allowed (`AgentSites`) gets it at once. `--shared` for any other asks on the agent's row, and Allow adds the
    /// site for every agent. The user's own command (not an agent's) gets it when it says `--shared`.
    func login(_ fields: [String: JSONValue], driver: Driver, asker: pid_t?) async throws -> JSONValue? {
        let shared = fields["shared"]?.bool == true
        guard let site = fields["url"]?.string.flatMap(AgentSites.site(of:)) else {
            if shared { throw RPCError.invalidParams("open --shared needs an HTTP or HTTPS site.") }
            return nil
        }
        if HostBrowser.page != nil {
            guard !shared else {
                throw RPCError.refused("Your login stays on this Mac: pages from an ssh host can't use it.")
            }
            return nil
        }
        let list = settings.store[SettingKeys.agentSites]
        if let allowed = AgentSites.allowed(site, in: AgentSites.entries(list)) { return .string(allowed) }
        guard shared else { return nil }
        guard let session = driver.session else { return .string(site) }
        guard let ls = asks.existing(session) else {
            throw RPCError.refused("open --shared runs in a session of Kelp's: its row asks the user.")
        }
        let denied = RPCError.refused("The user didn't let you use their login on \(site).")
        guard asks.permissions.deniedLogins.withLock({ $0[session]?.contains(site) != true }) else { throw denied }
        let home = settings.store.url.deletingLastPathComponent()   // the agents of this home, the user's own too
        let agent = AgentManifest.load(dir: Paths.agents(in: home)).first { $0.id == ls.snapshot.agent }?.name
        let question = Self.question(agent: agent ?? "the agent", site: site)
        let answer = await asks.permissions.waitForKelp(
            ls, question: question, within: UIBrowserAsk.wait, asker: asker, run: AgentSites.run(site))
        guard answer == "allow" else {
            // A command cut short (a tool's time limit) didn't hear a Deny: the chat may ask again.
            guard answer != PermissionWaits.askerGone else {
                throw RPCError.refused("Your command ended before the user answered about \(site): ask again.")
            }
            _ = asks.permissions.deniedLogins.withLock { $0[session, default: []].insert(site) }
            guard answer == "deny" else {
                throw RPCError.refused("Nobody answered whether you may use the user's login on \(site).")
            }
            throw denied
        }
        let now = settings.store[SettingKeys.agentSites]   // read again: the user may have changed it meanwhile
        let added = AgentSites.adding(site, chat: ls.snapshot.displayTitle, to: now)
        _ = try settings.store.set(SettingKeys.agentSites.key, .array(added))
        settings.changedBeforeReply()   // the app hears the site is allowed before it opens the page
        return .string(site)
    }

    /// What the agent's row asks. Allow keeps the site in Settings › Browser.
    static func question(agent: String, site: String) -> String { AgentSites.question(agent: agent, site: site) }
}
