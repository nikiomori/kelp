import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WebKit
import WorkbenchKit

@testable import BuiltinBrowser
@testable import KelpKit

/// A page an agent on a host drives is on the host's network: its loads go through the host's proxy, the host shows
/// before the address, and this Mac's own loopback is closed to it but for the ports forwarded from the host.
@MainActor @Test(.timeLimit(minutes: 1)) func aPageDrivenFromAHostReachesOnlyItsForwardedPorts() async throws {
    let tab = BrowserTab(uri: TabURI.agentPage("about:blank"), app: AppModel())
    try await tab.onHost(.object(["host": "box", "proxy": .int(1), "ports": .array([.int(3001)])]))
    #expect(!tab.hostChip.isHidden && tab.hostChip.title == "box")
    #expect(tab.web.configuration.websiteDataStore.proxyConfigurations.count == 1)
    func failure(_ url: String) async throws -> String {
        tab.loadError = nil
        tab.load(url)
        _ = try await waitFor { tab.loadError != nil }
        return tab.loadError ?? ""
    }
    for closed in ["http://localhost:3002/", "http://127.0.0.1:8888/", "http://app.localhost:3001/"] {
        #expect(try await failure(closed).contains("content blocker"), "\(closed)")
    }
    // Nothing listens on the forwarded port in the test, so the load reaches the port and finds nobody.
    #expect(try await !failure("http://localhost:3001/").contains("content blocker"))
}
