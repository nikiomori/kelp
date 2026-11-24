// What the shell shows, outside the tab, of a page an agent drives (`AgentPages`): whose page it is, and what the agent
// did there last.
import AppKit
import Core
import KelpKit
import WebKit

extension BrowserTab {
    /// Records an agent's action that is about to be done on this page. The page is marked as the session's (and the
    /// subagent's) and lit, with this step as the last one. A call from outside a session (the user's own
    /// `kelp browser`) leaves no mark.
    func told(_ action: BrowserAction, _ args: JSONValue) {
        guard let session = args["session"]?.string, let tab = args["tab"]?.string,
            let workspace = args["workspace"]?.string
        else { return }
        let pages = AgentPages.of(app)
        var page =
            pages.pages[pageId]
            ?? AgentPages.Page(session: session, subagent: nil, workspace: workspace, tab: tab)
        page.session = session
        page.subagent = args["subagent"]?.string
        page.workspace = workspace
        page.tab = tab
        page.title = title
        page.url = web.url?.absoluteString ?? start
        page.color = Self.vivid(app.catalog.color(app.session(session)?.agent))
        pages.drives(pageId, page, handle: self)
        let subagent = args["subagent"]?.string
        if drive?.driver != session || drive?.subagent != subagent {
            drive?.driver = session
            drive?.subagent = subagent
            showAgentBar()   // the bar says which agent drives
        }
        let step = Self.step(action, args, named: args["ref"]?.string.flatMap { drive?.names[$0] })
        drive?.lastStep = step
        pages.acted(pageId, step)
    }

    /// Describes an action as the card lists it, such as `clicks “Pay now”` or `opens localhost:3000/checkout`.
    nonisolated static func step(_ action: BrowserAction, _ args: JSONValue, named: String?) -> String {
        let what = named.flatMap(shownName).map { " “\($0)”" } ?? ""
        switch action {
        case .click, .hover, .drag, .type, .upload: return verb(action) + what
        case .open:
            let url = URL(string: args["url"]?.string ?? "")
            let place = url.map { ($0.host ?? "") + ($0.port.map { ":\($0)" } ?? "") + $0.path } ?? ""
            return String(localized: "opens \(place.isEmpty ? args["url"]?.string ?? "" : place)")
        case .press: return String(localized: "presses \(args["key"]?.string ?? "")")
        case .scroll: return String(localized: "scrolls \(args["to"]?.string ?? "down")")
        case .snapshot: return String(localized: "reads the page")
        case .screenshot: return String(localized: "takes a screenshot")
        case .eval: return String(localized: "runs a script")
        case .wait: return String(localized: "waits for the page")
        case .back: return String(localized: "goes back")
        case .reload: return String(localized: "reloads")
        case .viewport: return String(localized: "sets the page’s size \(args["size"]?.string ?? "")")
        case .record: return String(localized: "records the page")
        case .dialog: return String(localized: "answers the page’s question")
        case .console: return String(localized: "reads the console")
        case .network: return String(localized: "reads the requests")
        case .info: return String(localized: "looks at the page")
        case .ask:
            return args["text"]?.string.map { String(localized: "asks you: \($0)") }
                ?? String(localized: "hears your answer")
        }
    }

    /// Counts an error the page reported (a console error, a request that failed), and keeps it as the last one for the
    /// card.
    func noteError(_ text: String) {
        let line = String(text.prefix(160))
        AgentPages.of(app).change(pageId) { page in
            page.errors += 1
            page.lastError = line
        }
    }

    /// Updates the page's address and title as the card shows them.
    func showDriven() {
        let title = title, url = web.url?.absoluteString ?? start
        AgentPages.of(app).change(pageId) { page in
            page.title = title
            page.url = url
        }
    }

    func picture() async -> NSImage? {
        let small = WKSnapshotConfiguration()
        small.snapshotWidth = 480
        do { return try await web.takeSnapshot(configuration: small) } catch {
            return nil   // WebKit can't draw the page now (between two documents), so the card keeps its last picture
        }
    }

    func bringForward() {
        if let host {
            host.pageSet.show(host.pageSet.pages.first { $0.tab === self }?.who)
        } else if agent {
            pageSet.show(nil)
        }
    }

    /// Tells the tab's row of pages that one of its pages acted, so the row shows it. Only a tab that already has pages
    /// tells it, so no row is made for a tab without one.
    func pageSetActed() {
        if agent, host == nil { pageSet.acted() }
    }

    func hold(_ user: Bool) {
        guard let drive, drive.takenOver != user else { return }
        if !user, drive.asked != nil { return done() }
        drive.takenOver = user
        showAgentBar()
    }
}
