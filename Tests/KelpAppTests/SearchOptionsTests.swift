import AppKit
import Core
import Testing

@testable import BuiltinFiles
@testable import KelpKit

extension AppOfItsOwn {
    @Test func searchOptionsAreEachWorkspacesOwn() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        var o = SearchOptions()
        o.regex = true
        o.matchCase = true
        await o.save(rig.app, workspace: "a")
        #expect(SearchOptions(rig.app, workspace: "a") == o)
        #expect(SearchOptions(rig.app, workspace: "b") == SearchOptions())
        await SearchOptions().save(rig.app, workspace: "a")
        #expect(SearchOptions(rig.app, workspace: "a") == SearchOptions())
    }
}
