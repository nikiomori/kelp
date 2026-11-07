import Foundation
import Testing

@testable import Core

private let page = """
    # GRDB 7: four decisions

    Pick one in each; your picks come back to me.

    ## 1. Records that lose their implicit defaults
    - [ ] A. Write defaults into each init(from:) *recommended*
      Nine small edits; decoding stays strict.
    - [ ] B. A migration that fills the columns once

    ## 2. How the upgrade lands
    - [ ] A. One pull request *recommended*
    - [ ] B. Store by store, behind a setting

    """

@Test func reviewIsRead() {
    let r = Review(page)
    #expect(r.title == "GRDB 7: four decisions" && r.intro == "Pick one in each; your picks come back to me.")
    #expect(r.points.map(\.number) == ["1", "2"] && r.points[1].question == "How the upgrade lands")
    #expect(
        r.points[0].options[0]
            == .init(
                key: "A", text: "Write defaults into each init(from:)",
                detail: "Nine small edits; decoding stays strict.", recommended: true, picked: false))
    #expect(r.points[0].pick == nil)
}

/// Picks and notes are written into the file, where the agent reads them; the line it gets says the same.
@Test func reviewAnswersGoIntoTheFile() {
    var text = Review.pick(page, point: "1", option: "B")
    text = Review.pick(text, point: "1", option: "A")
    text = Review.pick(text, point: "2", option: "B")
    text = Review.note(text, point: "2", note: "CI has\nno real database")
    let r = Review(text)
    #expect(r.points.map(\.pick) == ["A", "B"] && r.points[1].note == "CI has no real database")
    #expect(text.contains("- [x] A. Write defaults into each init(from:) *recommended*\n  Nine small edits"))
    #expect(text.contains("- [x] B. Store by store, behind a setting\n> Note: CI has no real database\n"))
    #expect(r.answer(file: "review.md") == "My answers in review.md: 1A 2B. Note on 2: CI has no real database.")

    let changed = Review.note(text, point: "2", note: "fixtures")
    #expect(Review(changed).points[1].note == "fixtures" && !changed.contains("CI has"))
    #expect(!Review.note(changed, point: "2", note: "").contains("> Note:"))
    #expect(Review.pick(page, point: "9", option: "A") == page)
}

@Test func reviewFilesAreKnown() {
    #expect(Review.isReview("/p/.kelp/artifacts/grdb/review.md"))
    #expect(!Review.isReview("/p/docs/review.md") && !Review.isReview("/p/.kelp/artifacts/grdb/doc.md"))
    #expect(Review("# T\n").answer(file: "r.md") == "My answers in r.md: none picked.")
}
