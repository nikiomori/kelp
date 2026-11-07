import Core
import Testing
import WorkbenchKit

private let config = """
    root = true

    [*]
    indent_style = space
    indent_size = 4
    trim_trailing_whitespace = true

    [*.{js,ts}]
    indent_size = 2

    [Makefile]
    indent_style = tab

    [lib/**.py]
    indent_size = 8
    """

@Test func sectionsApplyInOrderAndAGlobMatchesNames() {
    #expect(EditorConfig.read(config, file: "a.swift").root)
    #expect(EditorConfig.read(config, file: "src/x.ts").rules.tabSize == 2)
    #expect(EditorConfig.read(config, file: "x.swift").rules.tabSize == 4)
    #expect(EditorConfig.read(config, file: "x.swift").rules.trimTrailingWhitespace == true)
    #expect(EditorConfig.read(config, file: "sub/Makefile").rules.insertSpaces == false)
    #expect(EditorConfig.read(config, file: "lib/a/b.py").rules.tabSize == 8)
    #expect(EditorConfig.read(config, file: "other/b.py").rules.tabSize == 4)
}

@Test func theNearerFileHasTheSay() {
    var near = EditorRules(), far = EditorRules()
    near.tabSize = 2
    far.tabSize = 8
    far.insertSpaces = false
    #expect(near.over(far).tabSize == 2)
    #expect(near.over(far).insertSpaces == false)
}

@Test func convertingKeepsEachLinesDepth() {
    #expect(Indentation.tabs.applied(to: "a\n    b\n        c\n      d", tabSize: 4) == "a\n\tb\n\t\tc\n\t  d")
    #expect(Indentation.spaces(4).applied(to: "\tb\n\t\tc", tabSize: 4) == "    b\n        c")
}

@Test func savingTidiesLineEndsAndTheLastLine() {
    #expect(Indentation.cleaned("a  \nb\t\r\n", trim: true, finalNewline: false) == "a\nb\r\n")
    #expect(Indentation.cleaned("a", trim: false, finalNewline: true) == "a\n")
    #expect(Indentation.cleaned("", trim: true, finalNewline: true) == "")
    #expect(Indentation.cleaned("a  ", trim: false, finalNewline: false) == "a  ")
}

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
