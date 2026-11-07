import Agents
import AppKit
import Core
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    package static let browser = Builtin(
        "kelp.browser", "Browser", "Web pages as tabs, dev servers open automatically, Design Mode.", icon: "safari"
    ) { app in
        var contributions = Contributions()
        contributions.tabs = [
            TabProvider(
                schemes: ["http", "https", "about", "preview", TabURI.agentScheme],
                make: { BrowserTab(uri: $0, app: app) },
                browse: { tab, action, args in
                    guard let page = tab as? BrowserTab else { throw RPCError.invalidParams("That tab shows no page.") }
                    return try await page.browse(action, args)
                })
        ]
        contributions.editors = [
            EditorSpec(
                id: "browser.new", title: "Browser", icon: "safari",
                uri: { _ in "about:blank#\(UUID().uuidString.prefix(6))" })
        ]
        contributions.commands = [
            CommandSpec(id: "browser.new", title: "New Browser Tab", key: "shift+cmd+b") { args in
                app.workbench.open(args["url"]?.string ?? "about:blank#\(UUID().uuidString.prefix(6))")
            }
        ]
        return contributions
    }
}
