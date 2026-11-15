import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import KelpApp
@testable import KelpKit

extension AppOfItsOwn {
    /// A .kelp.yaml's templates are listed before the file is trusted (a file of layouts alone was never asked about, so
    /// they never showed), and used, one runs the project's command by name: the daemon checks the file's trust then and
    /// runs its text as it is, not as it was when the empty screen was drawn. What was opened meanwhile stays.
    @Test func aFilesTemplateIsListedUntrustedAndRunsItsCommandAsItIsNow() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        rig.app.extensions.reload()
        let wid = rig.workspace.id
        try rig.write(".kelp.yaml", "run: sleep 30\nlayout.dev: run | shell\n")
        let listed = await LayoutTemplates(app: rig.app).fromFile(rig.workspace)
        #expect(listed.map(\.name) == ["dev"])
        let dev = try #require(listed.first)
        #expect(dev.layout.manual == true)

        // Changed since it was listed, and trusted as it is now (`Runs.trust` asks only when it isn't).
        try rig.write(".kelp.yaml", "run: sleep 31\nlayout.dev: run | shell\n")
        let now = try await rig.client.call(ScriptsList(worktreeId: wid))
        _ = try await rig.client.call(ScriptsTrust(worktreeId: wid, digest: now.digest))
        await LayoutTemplates(app: rig.app).use(dev, in: wid)
        let tabs = rig.app.workbench.layouts[wid].allTabs.map(\.uri)
        #expect(tabs.count == 2 && tabs.allSatisfy { TabURI.scheme($0) == "session" }, "\(tabs)")
        let ran = try await rig.client.call(SessionList()).map(\.argv).joined().joined(separator: " ")
        #expect(ran.contains("sleep 31") && !ran.contains("sleep 30"), "\(ran)")
        #expect(rig.app.workbench.layouts[wid].manual == true)
    }
}
