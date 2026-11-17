import AppKit
import Core
import Foundation
import TestSupport
import Testing

@testable import BuiltinIssues
@testable import KelpKit

extension AppOfItsOwn {
    /// An issue started on a branch of its own gets the project's .kelp.yaml setup as New Group on Branch… does: not
    /// yet trusted, it's asked about there, rather than an agent left in a folder with nothing installed.
    @Test func anIssuesBranchAsksAboutItsSetup() async throws {
        let rig = try await AppRig(files: [".kelp.yaml": "setup: echo installed\n"])
        defer { rig.done() }
        rig.app.extensions.reload()
        rig.app.settings.apply([SettingKeys.defaultAgent.key: .string(Session.shellAgent)])
        let holder = NSViewController()
        holder.view = NSView()
        rig.show(holder, 400, 300)
        let window = try #require(holder.view.window)
        window.orderFrontRegardless()   // a window never on screen gets no sheet
        defer { window.orderOut(nil) }
        let issue = GitHub.Issue(
            number: 7, title: "Fix it", body: "", url: "", labels: [], assignees: [], state: "OPEN")
        IssueWork(app: rig.app, repoId: rig.project.id).startOnBranch(issue)
        #expect(try await waitFor(10) { window.attachedSheet != nil })
        if let asked = window.attachedSheet { window.endSheet(asked, returnCode: .alertSecondButtonReturn) }
    }
}
