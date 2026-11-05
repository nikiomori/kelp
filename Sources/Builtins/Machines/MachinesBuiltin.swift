import AppKit
import Core
import KelpKit

extension Builtins {

    /// A virtual machine as a tab ("vm:<name>"): its state, what runs in it and for which agent, its ports and folders.
    /// Opened from the sidebar's Machines block.
    package static let machines = Builtin("kelp.machines", "Machines", "Kelp's virtual machines: what runs in each, its ports and folders.",
                                          icon: "shippingbox") { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["vm"]) { MachineTab(uri: $0, app: app) }]
        return c
    }
}
