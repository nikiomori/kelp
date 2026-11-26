import Core
import Foundation
import TestSupport
import Testing
import WebKit
import WorkbenchKit

@testable import BuiltinBrowser
@testable import KelpKit

@MainActor
struct BrowserDataStoreTests {
    @Test(.timeLimit(minutes: 1)) func sessionCookiesAreKeptInTheirOwnProfiles() async throws {
        let session = Session(cwd: "/", command: "claude", agent: "claude")
        let other = Session(cwd: "/", command: "claude", agent: "claude")
        let domain = "\(session.id.lowercased()).example.com"
        let cookie = try #require(
            HTTPCookie(properties: [
                .domain: domain, .path: "/", .name: "login",
                .value: "test-only", .expires: Date().addingTimeInterval(3600)
            ]))
        #expect(!cookie.isSessionOnly)
        let url = try #require(URL(string: "https://\(domain)/"))
        func loadDocument(_ tab: BrowserTab) async throws {
            tab.web.loadHTMLString("<title>Synthetic login</title>", baseURL: url)
            try await waitFor { tab.web.url == url && !tab.web.isLoading }
        }
        let app = AppModel()
        app.sessions = [session, other]
        let uri = TabURI.agentPage("about:blank", session: session.id)
        do {
            let tab = BrowserTab(uri: uri, app: app)
            let store = tab.web.configuration.websiteDataStore
            #expect(store.isPersistent && store.identifier?.uuidString == session.id)
            await store.httpCookieStore.setCookie(cookie)
            try await loadDocument(tab)
            #expect(TabURI.agentPageSession(tab.uri) == session.id)
            _ = try await tab.web.evaluateJavaScript("localStorage.setItem('login', 'test-only')")
        }
        let reopened = BrowserTab(uri: uri, app: app)
        let reopenedStore = reopened.web.configuration.websiteDataStore
        await #expect(throws: RPCError.self) {
            try await reopened.onHost(.object(["host": "box", "proxy": .int(1)]))
        }
        #expect(reopenedStore.proxyConfigurations.isEmpty)
        let cookies = await reopenedStore.httpCookieStore.allCookies()
        #expect(cookies.contains { $0.name == cookie.name && $0.value == cookie.value })
        try await loadDocument(reopened)
        #expect(try await reopened.web.evaluateJavaScript("localStorage.getItem('login')") as? String == "test-only")

        let second = BrowserTab(uri: TabURI.agentPage("about:blank", session: other.id), app: app)
        let secondStore = second.web.configuration.websiteDataStore
        #expect(secondStore.isPersistent && secondStore.identifier?.uuidString == other.id)
        #expect(await secondStore.httpCookieStore.allCookies().isEmpty)
        try await loadDocument(second)
        #expect(try await second.web.evaluateJavaScript("localStorage.getItem('login')") as? String == nil)
        await reopenedStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    @Test func pagesWithoutAGenuineSessionHaveAnEphemeralStore() {
        let app = AppModel(), session = Session(cwd: "/", command: "claude", agent: "claude")
        let terminal = Session(cwd: "/", command: "sh")
        app.sessions = [session, terminal]
        for owner in [nil, "user", "remote:\(session.id)", UUID().uuidString, terminal.id] {
            let uri = TabURI.agentPage("about:blank", session: owner)
            let store = BrowserTab(uri: uri, app: app).web.configuration.websiteDataStore
            #expect(!store.isPersistent && store.identifier == nil)
        }
        let userStore = BrowserTab(uri: "about:blank", app: app).web.configuration.websiteDataStore
        #expect(userStore.isPersistent && userStore.identifier == nil)
    }

    @Test(.timeLimit(minutes: 1)) func aNativeSubagentOpeningFirstLeavesTheParentItsProfile() async throws {
        let app = AppModel()
        let session = Session(cwd: "/", command: "claude", agent: "claude")
        app.sessions = [session]
        let parent = BrowserTab(uri: TabURI.agentPage("", session: session.id), app: app)
        _ = try await parent.browse(
            .open,
            .object([
                "url": "about:blank#native", "session": .string(session.id), "subagent": "native"
            ]))
        let native = try #require(parent.pageSet.pages.first?.tab)
        #expect(!native.web.configuration.websiteDataStore.isPersistent)
        #expect(TabURI.agentPageSession(native.uri) == nil)
        #expect(parent.web.url == nil)

        _ = try await parent.browse(.open, .object(["url": "about:blank#parent", "session": .string(session.id)]))
        #expect(parent.web.configuration.websiteDataStore.identifier?.uuidString == session.id)
        #expect(parent.web.configuration.websiteDataStore !== native.web.configuration.websiteDataStore)
    }
}
