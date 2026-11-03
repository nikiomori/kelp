import AppKit
import Foundation
import Testing
import Core
import WorkbenchKit
@testable import KelpKit
@testable import BuiltinBrowser

/// `kelp browser` on a real page, off screen: the snapshot lists what's shown with refs, typing and a click reach the
/// page's own code, and a ref the page no longer has says so.
@MainActor @Test(.timeLimit(.minutes(1))) func browserDrivesAPage() async throws {
    let tab = BrowserTab(uri: TabURI.agentPage("about:blank"), app: AppModel())
    #expect(tab.agent && tab.uri == "agentweb:about:blank")
    tab.web.loadHTMLString("""
        <title>Shop</title><h1>Cart</h1>
        <label>Email <input id="email"></label>
        <button onclick="document.getElementById('out').textContent = 'saved ' + document.getElementById('email').value">Save</button>
        <div style="display: none"><button>Hidden</button></div>
        <a href="/docs">Docs</a><p id="out"></p>
        """, baseURL: URL(string: "http://localhost/"))
    _ = try await tab.browse("info", .object([:]))

    let page = try #require(try await tab.browse("snapshot", .object([:])).string)
    #expect(page.contains(#"- heading "Cart" [level=1]"#))
    #expect(page.contains(#"- textbox "Email" [ref=e1]"#))
    #expect(page.contains(#"- button "Save" [ref=e2]"#))
    #expect(page.contains(#"- link "Docs" [ref=e3] -> /docs"#))
    #expect(!page.contains("Hidden"))

    _ = try await tab.browse("type", .object(["ref": .string("e1"), "text": .string("a@b.c")]))
    _ = try await tab.browse("click", .object(["ref": .string("e2")]))
    #expect(try await tab.browse("eval", .object(["js": .string("document.getElementById('out').textContent")])) == .string("saved a@b.c"))
    #expect(try await tab.browse("eval", .object(["js": .string("({n: 1 + 1})")])) == .object(["n": .int(2)]))
    _ = try await tab.browse("wait", .object(["text": .string("saved")]))

    await #expect(throws: RPCError.self) { try await tab.browse("click", .object(["ref": .string("e9")])) }
}
