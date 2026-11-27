import AppKit
import Core
import KelpKit
import WorkbenchKit

extension Builtins {

    package static let browser = Builtin(
        "kelp.browser", "Browser", "Web pages as tabs, dev servers open automatically, Design Mode.", icon: "safari"
    ) { app in
        return Contributions(
            editors: [
                EditorSpec(
                    id: "browser.new", title: "Browser", icon: "safari",
                    uri: { _ in "about:blank#\(UUID().uuidString.prefix(6))" })
            ],
            commands: [
                CommandSpec(id: "browser.new", title: "New Browser Tab", key: "shift+cmd+b") { args in
                    app.workbench.open(args["url"]?.string ?? "about:blank#\(UUID().uuidString.prefix(6))")
                },
                // What the browser tab in front does from its bar and its ⋯ menu.
                pageCommand(app, "browser.design", "Design Mode") { $0.toggleDesign() },
                pageCommand(app, "browser.openOutside", "Open in Browser") { $0.openExternal() },
                pageCommand(app, "browser.reloadFromOrigin", "Reload Ignoring Cache") {
                    $0.reloadPage(fromOrigin: true)
                },
                pageCommand(app, "browser.copyScreenshot", "Copy Screenshot") { $0.copyScreenshot() },
                pageCommand(app, "browser.recordVideo", "Record Video", when: { $0.recording == nil }) {
                    $0.recordFromMenu(gif: false)
                },
                pageCommand(app, "browser.recordGIF", "Record GIF", when: { $0.recording == nil }) {
                    $0.recordFromMenu(gif: true)
                },
                pageCommand(app, "browser.stopRecording", "Stop Recording", when: { $0.recording != nil }) {
                    $0.saveRecording()
                },
                pageCommand(app, "browser.clearSiteData", "Clear Cookies and Data for This Site…") {
                    $0.clearSiteData()
                }
            ],
            settings: [browserSettings(app)],
            tabs: [
                TabProvider(
                    schemes: ["http", "https", "about", "preview", TabURI.agentScheme],
                    make: { BrowserTab(uri: $0, app: app) },
                    placeholder: { uri in
                        guard TabURI.scheme(uri) == "preview" else {
                            let host = URL(string: TabURI.pageURL(uri))?.host
                            return (host ?? String(localized: "New Page"), .symbol("safari"), uri)
                        }
                        let path = TabURI.body(uri)
                        return ((path as NSString).lastPathComponent, .symbol("eye"), path)
                    },
                    driven: { BrowserMarks.driven($0, app) })
            ],
            // A page an agent drives puts a mark on the agent's row. A project's menu says whether new chats in the
            // project get the browser skill.
            rowMarks: [{ BrowserMarks.row($0, app) }],
            rowMenu: [{ BrowserMarks.menu($0, $1, app) }],
            skills: [browserSkill],
            agentCards: [{ BrowserMarks.card($0, app, close: $1) }],
            subagentSteps: [{ BrowserMarks.step($0, $1, $2, app) }],
            events: [
                {
                    guard let request = $0 as? UIBrowserEvent else { return false }
                    BrowserRequests(app: app).browse(request)
                    return true
                }
            ]
        )
    }
}

extension Builtins {
    /// A command for the page in front (a subagent's, when its tab shows one), enabled while `when` holds there.
    fileprivate static func pageCommand(
        _ app: AppModel, _ id: String, _ title: String, when: @escaping @MainActor (BrowserTab) -> Bool = { _ in true },
        _ run: @escaping @MainActor (BrowserTab) -> Void
    ) -> CommandSpec {
        CommandSpec(
            id: id, title: title,
            enabled: { (app.workbench.focusedContent as? BrowserTab).map { when($0.shownPage) } ?? false }
        ) { _ in
            guard let tab = app.workbench.focusedContent as? BrowserTab else { return NSSound.beep() }
            run(tab.shownPage)
        }
    }
}
