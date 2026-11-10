import Core
import Testing
import WorkbenchKit

@Test func aServersEditsApplyAsOfTheTextTheyWereMadeFor() {
    let edits = [
        CodeEdit(line: 0, column: 4, endLine: 0, endColumn: 7, text: "total"),
        CodeEdit(line: 1, column: 6, endLine: 1, endColumn: 9, text: "total"),
        CodeEdit(line: 2, column: 0, endLine: 2, endColumn: 0, text: "// end\n")
    ]
    #expect(TextEdits.applied(edits, to: "let sum = 1\nprint(sum)\n") == "let total = 1\nprint(total)\n// end\n")
}

@Test func aLineIsEditedOnlyIfItIsStillWhatWasShown() {
    #expect(TextEdits.replacing(line: 2, expected: "b", with: "B", in: "a\nb\nc\n") == "a\nB\nc\n")
    #expect(TextEdits.replacing(line: 1, expected: "a", with: "A", in: "a\r\nb\r\n") == "A\r\nb\r\n")
    #expect(TextEdits.replacing(line: 2, expected: "old", with: "B", in: "a\nb\n") == nil)
    #expect(TextEdits.replacing(line: 9, expected: "a", with: "B", in: "a\n") == nil)
}
