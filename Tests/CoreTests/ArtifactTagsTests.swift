import Foundation
import Testing

@testable import Core

/// A tag is kept lower case, its words joined by dashes, without `#`; nothing left is no tag.
@Test(arguments: [
    ("Design System", "design-system"), ("#review", "review"), ("  ", nil), ("a, b", "a-b"), ("Ревью", "ревью")
])
func artifactTagsAreKeptOneWay(word: String, tag: String?) {
    #expect(Artifacts.tag(word) == tag)
}

/// An agent's changes keep what the page had before its first one, so one Undo puts the page back as the user left it;
/// a change by the user forgets the agent's, and a change that changes nothing keeps the record as it was.
@Test func anAgentsChangeIsUndoneAsOne() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var page = ArtifactRecord(type: "doc", title: "T", created: now)
    page.tags = ["mine"]
    func change(_ r: ArtifactRecord, add: [String] = [], remove: [String] = [], archived: Bool? = nil, by: String?)
        -> ArtifactRecord
    {
        Artifacts.changed(r, add: add, remove: remove, archived: archived, session: by, undo: false, now: now)
    }
    let first = change(page, add: ["Research"], by: "s1")
    let second = change(first, remove: ["mine"], archived: true, by: "s1")
    #expect(second.tags == ["research"] && second.archived == true)
    #expect(second.agentChange?.tags == ["mine"] && second.agentChange?.archived == nil)

    let undone = Artifacts.changed(second, add: [], remove: [], archived: nil, session: nil, undo: true, now: now)
    #expect(undone.tags == ["mine"] && undone.archived == nil && undone.agentChange == nil)

    #expect(change(second, add: ["x"], by: nil).agentChange == nil)
    #expect(change(page, add: ["mine"], by: "s1") == page)
}
