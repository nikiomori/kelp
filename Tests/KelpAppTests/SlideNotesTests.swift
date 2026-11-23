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
