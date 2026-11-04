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
        <a href="/docs">Docs</a><p id="out"></p><span role="link">Ghost</span>
        """, baseURL: URL(string: "http://localhost/"))
    _ = try await tab.browse("info", .object([:]))
    #expect(try await tab.browse("eval", .object(["js": .string("innerWidth > 0 && innerHeight > 0")])) == .bool(true))

    let page = try #require(try await tab.browse("snapshot", .object([:])).string)
    #expect(page.contains(#"- heading "Cart" [level=1]"#))
    #expect(page.contains(#"- textbox "Email" [ref=e1]"#))
    #expect(page.contains(#"- button "Save" [ref=e2]"#))
    #expect(page.contains(#"- link "Docs" [ref=e3] -> /docs"#))
    #expect(!page.contains("Hidden"))
    #expect(page.contains(#"- link "Ghost" [ref=e4]"#) && !page.contains("Ghost\" [ref=e4] ->"))

    _ = try await tab.browse("type", .object(["ref": .string("e1"), "text": .string("a@b.c")]))
    _ = try await tab.browse("click", .object(["ref": .string("e2")]))
    #expect(try await tab.browse("eval", .object(["js": .string("document.getElementById('out').textContent")])) == .string("saved a@b.c"))
    #expect(try await tab.browse("eval", .object(["js": .string("({n: 1 + 1})")])) == .object(["n": .int(2)]))
    _ = try await tab.browse("wait", .object(["text": .string("saved")]))

    await #expect(throws: RPCError.self) { try await tab.browse("click", .object(["ref": .string("e9")])) }
}

/// An agent's page keeps what it logged from its first script on, and its fetch calls, failed ones too.
@MainActor @Test(.timeLimit(.minutes(1))) func browserKeepsConsoleAndRequests() async throws {
    let tab = BrowserTab(uri: TabURI.agentPage("about:blank"), app: AppModel())
    tab.web.loadHTMLString("<script>console.log('hi', {a: 1})</script><p>x</p>", baseURL: URL(string: "http://127.0.0.1:9/"))
    _ = try await tab.browse("info", .object([:]))
    _ = try await tab.browse("eval", .object(["js": .string("fetch('/api/x').catch(() => 0).then(() => console.error(new Error('boom')))")]))
    let end = Date().addingTimeInterval(5)
    while !tab.logs.contains(where: { $0.contains("boom") }), Date() < end { try await Task.sleep(for: .milliseconds(100)) }

    let log = try #require(try await tab.browse("console", .object(["clear": .bool(true)])).string)
    #expect(log.contains(#"[log] hi {"a":1}"#) && log.contains("[error] boom") && log.contains("[page] http://127.0.0.1:9/"))
    #expect(try await tab.browse("console", .object([:])) == .string("No console messages."))
    let net = try #require(try await tab.browse("network", .object([:])).string)
    #expect(net.contains("failed GET http://127.0.0.1:9/api/x (fetch"))
}

/// Keys do what the browser would (Tab moves on, Enter clicks), a hover reaches the page's handler, a scroll moves
/// the page.
@MainActor @Test(.timeLimit(.minutes(1))) func browserPressesHoversAndScrolls() async throws {
    let tab = BrowserTab(uri: TabURI.agentPage("about:blank"), app: AppModel())
    tab.web.loadHTMLString("""
        <input id="a"><button onclick="out.textContent += 'clicked '">Go</button>
        <div onmouseenter="out.textContent += 'hovered '">Menu</div><p id="out"></p>
        <script>addEventListener('keydown', e => { if (e.key === 'Escape') out.textContent += 'escape ' })</script>
        <div style="height: 5000px"></div>
        """, baseURL: URL(string: "http://localhost/"))
    _ = try await tab.browse("info", .object([:]))
    _ = try await tab.browse("snapshot", .object([:]))
    func out() async throws -> JSONValue { try await tab.browse("eval", .object(["js": .string("out.textContent")])) }

    _ = try await tab.browse("press", .object(["key": .string("Tab"), "ref": .string("e1")]))
    #expect(try await tab.browse("eval", .object(["js": .string("document.activeElement.localName")])) == .string("button"))
    _ = try await tab.browse("press", .object(["key": .string("Enter")]))
    _ = try await tab.browse("press", .object(["key": .string("Esc")]))
    #expect(try await out() == .string("clicked escape "))
    await #expect(throws: RPCError.self) { try await tab.browse("press", .object(["key": .string("Hyper")])) }

    let page = try #require(try await tab.browse("snapshot", .object([:])).string)
    #expect(!page.contains("hovered"))
    _ = try await tab.browse("eval", .object(["js": .string("document.querySelector('div').setAttribute('role', 'button')")]))
    let menu = try #require(try await tab.browse("snapshot", .object([:])).string?.split(separator: "\n")
        .first { $0.contains("\"Menu\"") }.flatMap { $0.firstMatch(of: /ref=(e\d+)/)?.1 })
    _ = try await tab.browse("hover", .object(["ref": .string(String(menu))]))
    #expect(try await out() == .string("clicked escape hovered "))

    let down = try await tab.browse("scroll", .object(["to": .string("down")]))
    #expect(down["scroll"]?.string?.hasPrefix("0 of") == false)

}

/// Back goes to the page a click left; opening the page it shows, or reload, loads it again.
@MainActor @Test(.timeLimit(.minutes(1))) func browserGoesBack() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-back-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(#"<a href="two.html">Two</a>"#.utf8).write(to: dir.appendingPathComponent("one.html"))
    try Data("<p>two</p>".utf8).write(to: dir.appendingPathComponent("two.html"))
    let tab = BrowserTab(uri: TabURI.agentPage("about:blank"), app: AppModel())
    await #expect(throws: RPCError.self) { try await tab.browse("back", .object([:])) }
    tab.web.loadFileURL(dir.appendingPathComponent("one.html"), allowingReadAccessTo: dir)
    _ = try await tab.browse("info", .object([:]))
    _ = try await tab.browse("snapshot", .object([:]))
    #expect(try await tab.browse("click", .object(["ref": .string("e1")]))["url"]?.string?.hasSuffix("two.html") == true)
    #expect(try await tab.browse("back", .object([:]))["url"]?.string?.hasSuffix("one.html") == true)

    // Opening the page it shows loads it again (a page's own state goes), as reload does.
    _ = try await tab.browse("eval", .object(["js": .string("window.kept = 1")]))
    let here = try #require(tab.web.url?.absoluteString)
    _ = try await tab.browse("open", .object(["url": .string(here)]))
    #expect(try await tab.browse("eval", .object(["js": .string("window.kept ?? 0")])) == .int(0))
    _ = try await tab.browse("eval", .object(["js": .string("window.kept = 1")]))
    _ = try await tab.browse("reload", .object([:]))
    #expect(try await tab.browse("eval", .object(["js": .string("window.kept ?? 0")])) == .int(0))
}

/// The user's own page tabs carry their logins: `kelp browser` drives only a page an agent opened, never one of those.
@MainActor @Test func anAgentDrivesOnlyItsOwnPage() async throws {
    let rig = try await AppRig(files: [:]); defer { rig.done() }
    let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
    _ = area.layout.add("https://example.com/", to: nil)   // as the tab's own (no provider here: `open` would hand it to Safari)
    #expect(area.browsedPage() == nil)
    _ = area.layout.add(TabURI.agentPage("about:blank"), to: nil)
    #expect(area.browsedPage()?.uri == TabURI.agentPage("about:blank"))
}
