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
    /// Puts the page on the host's network as the daemon said (`args.remote`: host, proxy, ports), before it loads.
    /// Connections the page already holds stay as they were until they close.
    func onHost(_ remote: JSONValue) async throws {
        guard agent, let host = remote["host"]?.string, let proxy = remote["proxy"]?.int,
            let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy))
        else { return }
        var socks = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))
        socks.allowFailover = false   // never straight from this Mac
        web.configuration.websiteDataStore.proxyConfigurations = [socks]
        let ports = (remote["ports"]?.array ?? []).compactMap(\.int).sorted()
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "kelp.host." + ports.map(String.init).joined(separator: "."),
            encodedContentRuleList: Self.loopbackRules(allowing: ports))
        let content = web.configuration.userContentController
        content.removeAllContentRuleLists()
        if let rules { content.add(rules) }
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
