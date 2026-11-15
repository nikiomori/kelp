import AppKit
import Core
import Testing
import WorkbenchKit

@testable import BuiltinGit
@testable import KelpKit

private func pr(_ n: Int, _ state: String) -> GitHub.PullRequest {
    GitHub.PullRequest(
        number: n, title: "", url: "", author: "", headRefName: "b", isDraft: false, state: state, checks: .init())
}

@Test func onlyAnOpenPRThatMergesIsNews() {
    #expect(MergedPR.justMerged(["w": pr(1, "MERGED")], was: ["w": pr(1, "OPEN")]).keys.sorted() == ["w"])
    #expect(MergedPR.justMerged(["w": pr(1, "MERGED")], was: [:]).isEmpty)   // merged when Kelp opened
    #expect(MergedPR.justMerged(["w": pr(1, "MERGED")], was: ["w": pr(1, "MERGED")]).isEmpty)   // said already
    #expect(MergedPR.justMerged(["w": pr(1, "CLOSED")], was: ["w": pr(1, "OPEN")]).isEmpty)
    #expect(MergedPR.justMerged(["w": pr(2, "MERGED")], was: ["w": pr(1, "OPEN")]).isEmpty)   // another branch's
}

@Test func anAgentAtWorkOrUncommittedFilesHoldTheSwitch() {
    #expect(MergedPR.next(base: "main", working: false, uncommitted: 0) == .switchTo("main"))
    #expect(MergedPR.next(base: "main", working: true, uncommitted: 3) == .agentWorking)
    #expect(MergedPR.next(base: "main", working: false, uncommitted: 3) == .uncommitted(3))
}

/// A branch's PR is Git's mark: "#12" beside its folder from what's pushed, and no mark at all with Git off.
@MainActor @Test func aPullRequestMarkIsGits() {
    _ = testHome
    _ = NSApplication.shared   // reload applies the theme to NSApp
    let m = AppModel(builtins: [Builtins.git])
    m.extensions.reload()
    m.worktrees = [Worktree(id: "w1", repoId: "r1", branch: "b", path: "/tmp/kelp-pr-mark")]
    m.land(PREvent(worktree: "w1", pr: pr(12, "OPEN")))
    #expect(m.extensions.all.ci?.pr("w1")?.title.string == "#12")
    // A click opens the PR in its own tab, as the Issues panel and Quick Open's "#" do: not its page in a browser tab.
    #expect(m.extensions.all.ci?.pr("w1")?.uri == TabURI.pullRequest(repo: "r1", number: 12))
    #expect(TabURI.pullRequest(repo: "r1", number: 12) == "pr:r1/12")
    #expect(m.extensions.all.ci?.pr("w2") == nil)
    let off = AppModel(builtins: [])
    off.extensions.reload()
    #expect(off.extensions.all.ci == nil)
}

/// The CI mark beside a folder is Git's to draw (`FolderCI.mark`): the shell only places it and says its state.
@MainActor @Test func theCIMarkIsGits() {
    _ = testHome
    _ = NSApplication.shared
    let m = AppModel(builtins: [Builtins.git])
    m.extensions.reload()
    let mark = m.extensions.all.ci?.mark()
    #expect(mark?.view is CIMark)
    #expect(mark?.show(nil, false) == 0 && mark?.view.isHidden == true)
    _ = mark?.show(.failed, false)
    #expect(mark?.view.isHidden == false)
}

/// A row or chip made before Git was on still shows Git's CI mark once there's a state to show.
@MainActor @Test func aCISlotTakesTheMarkWhenThereIsOne() {
    _ = testHome
    _ = NSApplication.shared
    let m = AppModel(builtins: [Builtins.git])
    let slot = CIMarkSlot(m)   // before the built-ins' contributions are read
    slot.state = .failed
    #expect(slot.view.subviews.isEmpty)
    m.extensions.reload()
    slot.state = .running
    #expect(slot.view.subviews.first is CIMark)
    #expect(slot.view.subviews.first?.isHidden == false)
    slot.state = nil
    #expect(slot.view.subviews.first?.isHidden == true)
}
