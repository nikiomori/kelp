import AppKit
import Core
import DesignKit
import Testing

@testable import BuiltinDatabases
@testable import BuiltinMachines
@testable import KelpKit

/// A database's dot has a colour only when it is broken: grey and filled while it answers, a grey ring while its
/// compose service is stopped, red when it doesn't answer, and none before it was tried.
@Test func aDatabasesDotIsRedOnlyWhenItIsDown() {
    let cases: [(DatabaseHealth.State?, NSColor?, Bool)] = [
        (.ok, .secondaryLabelColor, false), (.stopped, .secondaryLabelColor, true), (.down, .systemRed, false),
        (.unknown, nil, false), (nil, nil, false)
    ]
    for (state, color, ring) in cases {
        let dot = DatabaseLook.dot(state)
        #expect(dot?.color == color && (dot?.ring ?? false) == ring, "\(String(describing: state))")
    }
}

/// Forgetting a database asks first, so its menu item ends with "…".
@MainActor @Test func forgettingADatabaseAsksFirst() {
    let menu = NSMenu()
    let shop = DatabaseInfo(name: "shop", engine: .postgres)
    DatabaseMenu.fill(menu, shop, app: AppModel(builtins: []), worktreeId: "w")
    #expect(menu.items.contains { $0.title == "Forget…" })
    #expect(!menu.items.contains { $0.title == "Forget" })
}

/// A running machine says so in grey: only a machine that failed is red.
@MainActor @Test func aRunningMachineIsGrey() {
    let box = VMMachine(name: "box", os: "linux", image: "ubuntu", cpus: 2, memoryMiB: 2048, diskGiB: 16, user: "me")
    var v = VMInfo(machine: box, state: .running)
    #expect(Machines.machineWord(v).color == .secondaryLabelColor)
    v.state = .error
    #expect(Machines.machineWord(v).color == .textRed)
}
