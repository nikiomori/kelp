import AppKit
import Core
import DesignKit
import Network
import WebKit

/// A page an agent on a remote project's host drives (kelpd's `HostBrowser`) is on that host's network. Its loads go
/// through a SOCKS proxy on the host's connection, so names are looked up there. WebKit never sends loopback through
/// a proxy, so the host's localhost comes as ports forwarded here, and this Mac's own loopback is closed to the page
/// but for those ports: a program on the host can't reach the Mac's own servers through the page.
extension BrowserTab {
    var requiresHostNetwork: Bool { (host ?? self).ownerSession?.hasPrefix(AgentPages.remotePrefix) == true }
    var awaitsHostNetwork: Bool { requiresHostNetwork && hostChip.isHidden }

    /// Puts the page on the host's network as the daemon said (`args.remote`: host, proxy, ports), before it loads.
    /// Connections the page already holds stay as they were until they close.
    func onHost(_ remote: JSONValue) async throws {
        let store = web.configuration.websiteDataStore
        guard requiresHostNetwork, !store.isPersistent, let host = remote["host"]?.string, RemoteHost.isHost(host),
            let proxy = remote["proxy"]?.int, let value = UInt16(exactly: proxy), value != 0,
            let port = NWEndpoint.Port(rawValue: value)
        else { throw RPCError.invalidParams("This page needs a valid browser connection from its remote host.") }
        var socks = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))
        socks.allowFailover = false   // never straight from this Mac
        let ports = (remote["ports"]?.array ?? []).compactMap(\.int).sorted()
        guard
            let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "kelp.host." + ports.map(String.init).joined(separator: "."),
                encodedContentRuleList: Self.loopbackRules(allowing: ports))
        else { throw RPCError.internalError("Kelp couldn’t set the remote page’s network rules.") }
        let content = web.configuration.userContentController
        content.removeAllContentRuleLists()
        content.add(rules)
        store.proxyConfigurations = [socks]
        hostChip.title = host
        hostChip.toolTip = String(
            localized: "An agent on \(host) drives this page: localhost is \(host)’s, and the page loads through it")
        hostChip.isHidden = false
    }

    /// Dresses the host's chip before the address (`hostChip`), which opens the host's screen.
    func showHostChip() {
        hostChip.isHidden = true
        hostChip.padding = Metrics.gap
        hostChip.font = .ui(TextSize.caption)
        hostChip.restFill = .fillRest
        hostChip.onClick = { [weak self] in
            guard let self else { return }
            app.workbench.open("host:" + hostChip.title)
        }
    }

    /// Whether an address is a loopback one (localhost, 127.x, ::1), whose machine a page's address alone doesn't say.
    static func loopback(_ address: String) -> Bool {
        let host = URL(string: address.contains("://") ? address : "http://" + address)?.host?.lowercased() ?? ""
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "::1"
            || host == "0.0.0.0"
    }

    /// WebKit's content rules that block this Mac's loopback (any scheme, so WebSockets too) but for `ports`.
    static func loopbackRules(allowing ports: [Int]) -> String {
        let blocked = [#"localhost[:/]"#, #"[^/]*\.localhost[:/]"#, #"127\."#, #"0\.0\.0\.0[:/]"#, #"\[::1\]"#]
        let open = ports.flatMap { ["localhost:\($0)/", #"127\.0\.0\.1:"# + "\($0)/"] }
        // JSON by hand: a filter's backslashes are its only characters JSON escapes.
        func rule(_ filter: String, _ type: String) -> String {
            let escaped = ("^[a-z]+://" + filter).replacingOccurrences(of: "\\", with: "\\\\")
            return #"{"trigger":{"url-filter":""# + escaped + #""},"action":{"type":""# + type + #""}}"#
        }
        return "["
            + (blocked.map { rule($0, "block") } + open.map { rule($0, "ignore-previous-rules") })
            .joined(separator: ",") + "]"
    }
}
