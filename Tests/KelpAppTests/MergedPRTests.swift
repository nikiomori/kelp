import AppKit
import Core
import Testing

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
    m.land(PREvent(worktree: "w1", pr: pr(12, "OPEN")))
    #expect(m.extensions.all.ci?.pr("w1")?.title.string == "#12")
    #expect(m.extensions.all.ci?.pr("w2") == nil)
    let off = AppModel(builtins: [])
    off.extensions.reload()
    #expect(off.extensions.all.ci == nil)
}
