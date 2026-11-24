import Testing

@testable import BuiltinFiles

/// A slide's notes go into slides.md as its "Notes:" line: changed in place, added at the slide's end before its rule,
/// or taken away; another slide's lines stay as they are.
@Test(arguments: [
    (
        "# Deck\n\n---\n\n## Why\n- small\n\n---\n\n## End", 5, "Ask the room",
        "# Deck\n\n---\n\n## Why\n- small\n\nNotes: Ask the room\n\n---\n\n## End"
    ),
    ("## Why\n\nNotes: old\n\n---\n\n## End", 1, "new\nwords", "## Why\n\nNotes: new words\n\n---\n\n## End"),
    ("## Why\n\nNotes: old\n\n---\n\n## End", 1, "", "## Why\n\n---\n\n## End"),
    ("## Why\n\n---\n\n## End", 5, "last", "## Why\n\n---\n\n## End\n\nNotes: last")
])
func slideNotesGoIntoTheSource(source: String, line: Int, text: String, expected: String) {
    #expect(SlideNotes.set(source, line: line, text: text) == expected)
}

/// Other layouts of a slide come right after it, each starting with `<!-- variant -->`: they make a group, and
/// keeping one puts it, without the marker, in the group's place.
@Test func aSlidesVariantIsKept() throws {
    let deck =
        "# Deck\n\n---\n\n## Why\n- a\n\n---\n\n<!-- variant -->\n## Why, as a picture\n\n---\n\n<!-- variant -->\n## Why, in numbers\n\n---\n\n## End"
    #expect(SlideVariants.groups(deck) == [[5, 11, 16]])
    #expect(
        try #require(SlideVariants.keep(deck, line: 11)) == "# Deck\n\n---\n\n## Why, as a picture\n\n---\n\n## End")
    #expect(try #require(SlideVariants.keep(deck, line: 5)) == "# Deck\n\n---\n\n## Why\n- a\n\n---\n\n## End")
    #expect(SlideVariants.keep(deck, line: 1) == nil)
}
