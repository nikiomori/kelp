import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit
import KelpKit

extension Builtins {

    /// Off on a clean install: Settings › Extensions turns it on.
    package static let activity = Builtin("kelp.activity", "Activity", "CPU and memory of each agent and terminal, with Stop.",
                                          icon: "gauge.with.dots.needle.33percent", offByDefault: true) { app in
        var c = Contributions()
        c.panels = [PanelSpec(id: "activity", title: "Activity", icon: "gauge.with.dots.needle.33percent", extensionId: "kelp.activity") {
            ActivityController(app: app)
        }]
        return c
    }
}
