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
                }
            ],
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
            // The page an agent drives: a mark on its row, and in a project's menu whether new chats get the skill.
            rowMarks: [{ BrowserMarks.row($0, app) }],
            rowMenu: [{ BrowserMarks.menu($0, $1, app) }],
            skills: [browserSkill],
            agentCards: [{ BrowserMarks.card($0, app, close: $1) }],
            subagentSteps: [{ BrowserMarks.step($0, $1, $2, app) }],
            browser: { BrowserRequests(app: app).browse($0) }
        )
    }
}
