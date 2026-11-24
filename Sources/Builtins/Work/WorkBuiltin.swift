import AppKit
import Core
import KelpKit
import WorkbenchKit

extension Builtins {
    /// Where an agent worked: the inspector's Work panel (its steps, and its project in layers) and the Map tab (the
    /// same work as a tree of nodes, the project on one side and what it reached outside on the other).
    package static let work = Builtin(
        "kelp.work", "Work", "Where an agent worked: its steps, the files it read and edited, what it reached outside.",
        icon: "map"
    ) { app in
        // One choice of turn and agent per session, for the panel and the Map tab alike.
        let choices = WorkChoices()
        return Contributions(
            panels: [
                PanelSpec(id: "work", title: "Work", icon: "map", extensionId: "kelp.work") {
                    WorkPanel(app: app, choices: choices)
                }
            ],
            tabs: [
                TabProvider(
                    schemes: [WorkTab.scheme], make: { WorkTab(uri: $0, app: app, choices: choices) },
                    placeholder: { uri in
                        let title = WorkTab.title(app.session(TabURI.body(uri)), app: app)
                        return (title, .symbol("map"), nil)
                    })
            ]
        )
    }
}
