import AppKit
import Core
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    /// A virtual machine as a tab ("vm:<name>"): its state, what runs in it and for which agent, its ports and folders.
    /// Opened from the sidebar's Machines block, there once there's a machine; File › New Machine… makes the first.
    package static let machines = Builtin(
        "kelp.machines", "Machines", "Kelp's virtual machines: what runs in each, its ports and folders.",
        icon: "shippingbox"
    ) { app in
        return Contributions(
            commands: [cmd("machines.new", "New Machine…") { Machines.chooseNew(app) }],
            tabs: [
                TabProvider(
                    schemes: ["vm"], make: { machineTab(uri: $0, app: app) },
                    placeholder: { (TabURI.body($0), .symbol("shippingbox"), nil) })
            ],
            sidebarSections: [
                SidebarSection(id: "machines") {
                    // Kelp's virtual machines, once there's one
                    let view = NSHostingView(rootView: MachinesView(app: app))
                    view.sizingOptions = [.intrinsicContentSize]
                    return view
                }
            ],
            // An agent running a command in a machine (`kelp vm run`) says so on its row.
            sessionMarks: [
                { session in
                    Machines.machineList(app).first { $0.sessions?.contains(session.id) == true }
                        .map {
                            SessionMark(
                                symbol: "shippingbox", tip: String(localized: "Runs a command in \($0.machine.name)"))
                        }
                }
            ],
            // A project's menu: Run Terminals In, while there's a machine that shares folders.
            rowMenu: [
                { row, menu in
                    guard case .project(let id) = row, let repo = app.repo(id) else { return }
                    Machines.addRunIn(to: menu, repo, app)
                }
            ],
            skills: [machinesSkill]
        )
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
