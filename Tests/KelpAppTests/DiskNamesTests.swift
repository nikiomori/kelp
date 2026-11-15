import Core
import Testing

@testable import BuiltinFiles

/// A remote project's disk is its host's, and what's chosen there goes aside on it: the foot of Files and the Disk
/// Usage tab don't say "this Mac" or "Trash" of it.
@Test func aRemoteProjectsDiskWordsNameItsHost() {
    let build = RepoDiskUsage.Item(path: "/p/.build", bytes: 3 << 20, what: .build, removable: true)
    let files = RepoDiskUsage.Item(path: "/p", bytes: 1 << 20, what: .files, removable: false)
    #expect(DiskNames.place(host: nil) == "on this Mac" && DiskNames.place(host: "box") == "on box")
    #expect(DiskNames.foot([files], host: nil) == "on this Mac" && DiskNames.foot([files], host: "box") == "on box")
    #expect(DiskNames.foot([files, build], host: "box") == "\(DiskNames.size(3 << 20)) rebuilds")
    #expect(DiskNames.move(count: 1, host: nil) == "Move 1 Item to Trash")
    #expect(DiskNames.move(count: 3, host: nil) == "Move 3 Items to Trash")
    #expect(DiskNames.move(count: 1, host: "box") == "Move 1 Item Aside")
    #expect(DiskNames.move(count: 3, host: "box") == "Move 3 Items Aside")
    #expect(DiskNames.aside(on: "box") == "Into the project’s .git/kelp-trash on box, which keeps them a week.")
}
