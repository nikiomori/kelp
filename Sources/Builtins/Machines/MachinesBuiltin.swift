import AppKit
import Core
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    /// A virtual machine as a tab ("vm:<name>"): its state, what runs in it and for which agent, its ports and
    /// folders. It opens from the sidebar's Machines block, which is there once a machine exists. File › New Machine…
    /// makes the first one.
    package static let machines = Builtin(
        "kelp.machines", "Machines", "Kelp’s virtual machines: what runs in each, its ports and folders.",
        icon: "shippingbox"
    ) { app in
        return Contributions(
            commands: [
                cmd("machines.new", "New Machine…") { Machines.chooseNew(app) },
                // What the machine's tab in front does from its bar and its ⋯ menu.
                machineCommand(
                    app, "machines.start", "Start Machine",
                    when: { [.sleeping, .off, .error].contains($0.state) && $0.notMade != true }
                ) { Machines.control(app, machine: $0.machine.name, .start) },
                machineCommand(
                    app, "machines.sleep", "Put Machine to Sleep", when: { [.running, .paused].contains($0.state) }
                ) { Machines.control(app, machine: $0.machine.name, .sleep) },
                machineCommand(
                    app, "machines.shutDown", "Shut Down Machine",
                    when: { [.running, .paused, .starting, .sleeping].contains($0.state) }
                ) { Machines.control(app, machine: $0.machine.name, .stop) },
                machineCommand(
                    app, "machines.showScreen", "Show Machine’s Screen",
                    when: { $0.machine.kind.hasScreen && Machines.usable($0) }
                ) { Machines.control(app, machine: $0.machine.name, .show) },
                machineCommand(app, "machines.terminal", "Open Terminal in Machine", when: Machines.usable) {
                    Machines.runInMachine(app, $0.machine.name)
                },
                machineCommand(app, "machines.delete", "Delete Machine…") { Machines.deleteMachine(app, $0) }
            ],
            tabs: [
                TabProvider(
                    schemes: ["vm"], make: { machineTab(uri: $0, app: app) },
                    placeholder: { (TabURI.body($0), .symbol("shippingbox"), nil) })
            ],
            sidebarSections: [
                SidebarSection(id: "machines") {
                    // Kelp's virtual machines, once there's one.
                    let view = NSHostingView(rootView: MachinesView(app: app))
                    view.sizingOptions = [.intrinsicContentSize]
                    return view
                }
            ],
            // An agent running a command in a machine (`kelp vm run`) says so on its row.
            rowMarks: [
                { row in
                    guard case .agent(let sid) = row else { return [] }
                    return Machines.machineList(app).filter { $0.sessions?.contains(sid) == true }.prefix(1).map {
                        let tip = String(localized: "Runs a command in \($0.machine.name)")
                        return RowMark(.chip, symbol: "shippingbox", tip: tip)
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

extension Builtins {
    /// A command for the machine whose tab is in front, enabled while `when` holds for it; elsewhere it beeps.
    fileprivate static func machineCommand(
        _ app: AppModel, _ id: String, _ title: String, when: @escaping @MainActor (VMInfo) -> Bool = { _ in true },
        _ run: @escaping @MainActor (VMInfo) -> Void
    ) -> CommandSpec {
        @MainActor func front() -> VMInfo? {
            guard let uri = app.workbench.focusedContent?.uri, TabURI.scheme(uri) == "vm" else { return nil }
            return Machines.machineList(app).first { $0.machine.name == TabURI.body(uri) }
        }
        return CommandSpec(id: id, title: title, enabled: { front().map { when($0) } ?? false }) { _ in
            guard let info = front() else { return NSSound.beep() }
            run(info)
        }
    }
}

// How the app keeps what the daemon pushes about machines. These event kinds belong to Machines, not to the shell.
extension MachinesEvent: Pushed {
    package var key: String { "" }
    package static var forgottenWith: WatchTopic? { nil }
}
extension MachineEvent: Pushed {
    package var key: String { name }
    package static var forgottenWith: WatchTopic? { .machineDetail }
}
