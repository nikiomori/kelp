import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinRun
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

    /// A template's project command is a run of Run's, as one from the Run menu is: kept as the workspace's run, and an
    /// earlier copy of it ended first rather than left beside the new one.
    @Test func aTemplatesCommandRunsAsRunRunsIt() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        rig.app.extensions.reload()
        let wid = rig.workspace.id
        try rig.write(".kelp.yaml", "run: sleep 30\nlayout.dev: run\n")
        let dev = try #require(await LayoutTemplates(app: rig.app).fromFile(rig.workspace).first)
        let now = try await rig.client.call(ScriptsList(worktreeId: wid))
        _ = try await rig.client.call(ScriptsTrust(worktreeId: wid, digest: now.digest))
        let runs = rig.app.part { Runs(app: rig.app) }
        await LayoutTemplates(app: rig.app).use(dev, in: wid)
        let first = try #require(runs.running(in: wid).first)
        #expect(runs.state.active[first]?.choice == "kelp:run")
        rig.app.workbench.layouts[wid] = WorkspaceLayout()   // the group emptied, the template used again
        await LayoutTemplates(app: rig.app).use(dev, in: wid)
        #expect(try await waitFor(5) { runs.running(in: wid).count == 1 && runs.running(in: wid) != [first] })
    }
}
