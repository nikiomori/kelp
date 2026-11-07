import Testing
import WorkbenchKit

@Test func aConventionalSubjectSplitsIntoTypeScopeAndASentence() {
    let s = CommitSubject("fix(daemon): start no agent while the daemon stops")
    #expect(s.type == "fix" && s.scope == "daemon" && !s.breaking)
    #expect(s.text == "Start no agent while the daemon stops")
    let bare = CommitSubject("feat!: add a folder without git as a project")
    #expect(bare.type == "feat" && bare.scope == nil && bare.breaking)
    #expect(bare.text == "Add a folder without git as a project")
}

@Test func aBodyReflowsIntoParagraphsButKeepsListsAndCode() {
    let body =
        "The daemon pauses its agents\nas it stops.\n\n\nIt now:\n- refuses a new agent\n- ends its program\n  at once\n\n    swift test\n1. then this"
    #expect(
        CommitSubject.reflow(body)
            == "The daemon pauses its agents as it stops.\n\nIt now:\n- refuses a new agent\n- ends its program\n  at once\n\n    swift test\n1. then this"
    )
}

@Test func namesKeepTheirCaseAndOtherSubjectsStayAsWritten() {
    #expect(CommitSubject("fix(daemon): SIGKILL only the processes").text == "SIGKILL only the processes")
    #expect(CommitSubject("docs: kelp.json fields").text == "kelp.json fields")
    #expect(CommitSubject("fix: don't wait").text == "Don't wait")
    for raw in ["Merge branch 'main'", "wip: try a thing", "fix(daemon):no space", "Add a folder"] {
        let s = CommitSubject(raw)
        #expect(s.type == nil && s.text == raw)
    }
}
