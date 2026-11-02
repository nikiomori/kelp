import Core
import Testing
@testable import KelpKit

private func pr(_ n: Int, _ state: String) -> GitHub.PullRequest {
    GitHub.PullRequest(number: n, title: "", url: "", author: "", headRefName: "b", isDraft: false, state: state, checks: .init())
}

@Test func onlyAnOpenPRThatMergesIsNews() {
    #expect(MergedPR.justMerged(["w": pr(1, "MERGED")], was: ["w": pr(1, "OPEN")]).keys.sorted() == ["w"])
    #expect(MergedPR.justMerged(["w": pr(1, "MERGED")], was: [:]).isEmpty)                  // merged when Kelp opened
    #expect(MergedPR.justMerged(["w": pr(1, "MERGED")], was: ["w": pr(1, "MERGED")]).isEmpty)  // said already
    #expect(MergedPR.justMerged(["w": pr(1, "CLOSED")], was: ["w": pr(1, "OPEN")]).isEmpty)
    #expect(MergedPR.justMerged(["w": pr(2, "MERGED")], was: ["w": pr(1, "OPEN")]).isEmpty)    // another branch's
}

@Test func anAgentAtWorkOrUncommittedFilesHoldTheSwitch() {
    #expect(MergedPR.next(base: "main", working: false, uncommitted: 0) == .switchTo("main"))
    #expect(MergedPR.next(base: "main", working: true, uncommitted: 3) == .agentWorking)
    #expect(MergedPR.next(base: "main", working: false, uncommitted: 3) == .uncommitted(3))
}
