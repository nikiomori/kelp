import Foundation
import Testing

@testable import Core

/// A task line reads the same whether a person or Kelp wrote it: its box, its words, how far it is set in, and Kelp's
/// facts from the comment the page doesn't show. Any other line is no task.
@Test(arguments: [
    ("- [ ] Dark diff", TaskLine(text: "Dark diff")),
    ("* [x] Ollama", TaskLine(text: "Ollama", state: .done)),
    ("- [X] Shout", TaskLine(text: "Shout", state: .done)),
    ("- [-] iCloud limits", TaskLine(text: "iCloud limits", state: .cancelled)),
    ("    - [ ] a step", TaskLine(text: "a step", depth: 2)),
    ("1. [ ] numbered", TaskLine(text: "numbered")),
    (
        "- [ ] Squeeze <!-- k:a2d4 proposed by:s1 at:1800000000 -->",
        TaskLine(id: "a2d4", text: "Squeeze", proposed: true, by: "s1", at: 1_800_000_000)
    ),
    (
        "- [ ] Dates <!-- k:5c20 chats:s1,s2 issue:https://github.com/o/r/issues/212 -->",
        TaskLine(id: "5c20", text: "Dates", chats: ["s1", "s2"], issue: "https://github.com/o/r/issues/212")
    ),
    ("- [ ] HTML <!-- a note --> stays", TaskLine(text: "HTML <!-- a note --> stays"))
])
func aTaskLineReads(raw: String, task: TaskLine) {
    #expect(TaskLines.line(raw) == task)
}

@Test(arguments: ["- plain item", "[ ] no bullet", "# - [ ] heading", "text - [ ] inside", ""])
func otherLinesAreNoTasks(raw: String) {
    #expect(TaskLines.line(raw) == nil)
}

/// Writing a line and reading it back gives the same task; a line with no id keeps no comment.
@Test(arguments: [
    TaskLine(text: "Dark diff"),
    TaskLine(id: "7f3a", text: "Fix the inset", state: .done, at: 1_800_000_000),
    TaskLine(id: "a2d4", text: "Squeeze", depth: 1, proposed: true, by: "s1", at: 1_800_000_000, chats: ["s9"]),
    TaskLine(id: "5c20", text: "Dates", state: .cancelled, issue: "https://linear.app/t/issue/LIN-42/x")
])
func aWrittenLineReadsBack(task: TaskLine) {
    #expect(TaskLines.line(TaskLines.written(task)) == task)
}

@Test func aLineWithoutAnIdIsWrittenWithoutAComment() {
    #expect(TaskLines.written(TaskLine(text: "Plain", chats: ["s1"])) == "- [ ] Plain")
}

/// The words a task reads as and the page it grew into, out of Markdown's link.
@Test func aLinkedTaskReadsItsTitleAndPage() {
    let task = TaskLines.line("- [ ] [Search chats](../search-chats/doc.md) <!-- k:91b0 -->")
    #expect(task?.title == "Search chats")
    #expect(task?.page == "../search-chats/doc.md")
    #expect(TaskLines.line("- [ ] see [docs](https://x.dev)")?.page == nil)
}

@Test(arguments: [
    ("https://github.com/o/r/issues/212", "#212"), ("https://linear.app/t/issue/LIN-42/title", "LIN-42"),
    ("https://kelp.atlassian.net/browse/KEL-7", "KEL-7")
])
func anIssueIsNamedAsItsTrackerNamesIt(url: String, ref: String) {
    #expect(TaskLine(text: "t", issue: url).issueRef == ref)
}

private let page = """
    # Tasks · kelp

    ## Inbox
    - [ ] Dark diff

    ## Now
    - [ ] Fix the inset <!-- k:7f3a -->
      - [x] measure it
    ### notes
    - [-] iCloud
    """

/// Each line knows its heading (the page's `#` title is none) and its place.
@Test func aPagesLinesKnowTheirSections() {
    let tasks = TaskLines.parse(page)
    #expect(tasks.map(\.text) == ["Dark diff", "Fix the inset", "measure it", "iCloud"])
    #expect(tasks.map(\.section) == ["Inbox", "Now", "Now", "notes"])
    #expect(tasks.map(\.line) == [4, 7, 8, 10])
    #expect(tasks.map(\.depth) == [0, 0, 1, 0])
}

/// A new line goes last under its heading, before the blank line that ends the section; under the first heading when
/// none is named; under a new heading at the end when the named one isn't there.
@Test(arguments: [
    ("Inbox", "## Inbox\n- [ ] Dark diff\n- [ ] New <!-- k:0001 -->\n\n## Now", 5),
    (nil, "## Inbox\n- [ ] Dark diff\n- [ ] New <!-- k:0001 -->\n\n## Now", 5),
    ("Now", "  - [x] measure it\n- [ ] New <!-- k:0001 -->\n### notes", 9),
    ("Later", "- [-] iCloud\n\n## Later\n- [ ] New <!-- k:0001 -->\n", 13)
])
func aNewTaskGoesUnderItsHeading(under: String?, around: String, line: Int) {
    let (text, at) = TaskLines.add(TaskLine(id: "0001", text: "New"), under: under, to: page, newSection: "Inbox")
    #expect(text.contains(around))
    #expect(at == line)
    #expect(text.components(separatedBy: "\n")[at - 1].hasPrefix("- [ ] New"))
}

@Test func aPageWithNoHeadingGetsItsInbox() {
    let (text, at) = TaskLines.add(TaskLine(text: "First"), under: nil, to: "# Tasks · kelp\n", newSection: "Inbox")
    #expect(text == "# Tasks · kelp\n\n## Inbox\n- [ ] First\n")
    #expect(at == 4)
}

/// A line is found by its id; one without an id by its line and words, so a line that moved isn't changed instead.
@Test func aChangeFindsItsLine() throws {
    let byId = try TaskLines.change(page, TaskRef(id: "7f3a")) { $0.state = .done }
    #expect(byId.text.contains("- [x] Fix the inset <!-- k:7f3a -->"))
    #expect(byId.task.line == 7)

    let byLine = try TaskLines.change(page, TaskRef(line: 4, text: "Dark diff")) { $0.chats = ["s1"] }
    #expect(byLine.task.id != nil && byLine.task.id != "7f3a")
    #expect(TaskLines.parse(byLine.text)[0].chats == ["s1"])

    #expect(throws: TaskLines.Failure.self) { try TaskLines.change(page, TaskRef(line: 4, text: "Moved")) { _ in } }
    #expect(throws: TaskLines.Failure.self) { try TaskLines.change(page, TaskRef(id: "none")) { _ in } }
    #expect(try TaskLines.remove(page, TaskRef(id: "7f3a")).contains("Fix the inset") == false)
}

/// A grown page's goal is its **Done when:** line, in any of Kelp's languages; an empty one is none.
@Test(arguments: [
    ("# T\n\n**Done when:** ⌘P finds a chat in 200 ms\n\n## Plan\n", "⌘P finds a chat in 200 ms"),
    ("**Готово, когда:** поиск за 200 мс", "поиск за 200 мс"), ("**Done when:** \n", nil), ("**Note:** later", nil),
    ("Done when: plain text", nil)
])
func aPagesGoalIsItsDoneWhenLine(text: String, goal: String?) {
    #expect(TaskLines.goal(text) == goal)
}
