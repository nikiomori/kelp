import AppKit
import Core
import KelpKit
import SwiftUI

extension Builtins {

    /// A virtual machine as a tab ("vm:<name>"): its state, what runs in it and for which agent, its ports and folders.
    /// Opened from the sidebar's Machines block.
    package static let machines = Builtin(
        "kelp.machines", "Machines", "Kelp's virtual machines: what runs in each, its ports and folders.",
        icon: "shippingbox"
    ) { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["vm"]) { MachineTab(uri: $0, app: app) }]
        c.sidebarSections = [
            SidebarSection(id: "machines") {
                let v = NSHostingView(rootView: MachinesView(app: app))   // Kelp's virtual machines, once there's one
                v.sizingOptions = [.intrinsicContentSize]
                return v
            }
        ]
        // An agent running a command in a machine (`kelp vm run`) says so on its row.
        c.sessionMarks = [
            { s in
                app.machineList.first { $0.sessions?.contains(s.id) == true }
                    .map {
                        SessionMark(
                            symbol: "shippingbox", tip: String(localized: "Runs a command in \($0.machine.name)"))
                    }
            }
        ]
        return c
    }
}

// How the app keeps what the daemon pushes about machines: Machines' own kinds, not the shell's.
extension MachinesEvent: Pushed {
    package var key: String { "" }
    package static var forgottenWith: WatchTopic? { nil }
}
extension MachineEvent: Pushed {
    package var key: String { name }
    package static var forgottenWith: WatchTopic? { .machineDetail }
}
