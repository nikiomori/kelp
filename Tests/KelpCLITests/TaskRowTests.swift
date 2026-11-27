import Core
import Foundation
import Testing

@testable import kelp

/// `kelp task list` prints a task as its name (its id, or `page:line` before it has one), its box (a proposal in round
/// brackets), its words without Markdown's link, and where it is.
@Test func aTaskListsAsOneLine() {
    let page = TaskPage(path: "/p/.kelp/artifacts/tasks/doc.md", slug: "tasks", title: "Tasks · kelp", tasks: [])
    #expect(Main.row(TaskLine(id: "7f3a", text: "Fix the inset", section: "Now"), page) == "7f3a\t[ ]\tFix the inset\ttasks › Now")
    #expect(Main.row(TaskLine(text: "Dark diff", line: 4, section: "Inbox"), page) == "tasks:4\t[ ]\tDark diff\ttasks › Inbox")
    #expect(Main.row(TaskLine(id: "a", text: "Squeeze", proposed: true), page) == "a\t( )\tSqueeze\ttasks")
    #expect(Main.row(TaskLine(id: "b", text: "[Search](../s/doc.md)", state: .done), nil) == "b\t[x]\tSearch")
    #expect(Main.row(TaskLine(id: "c", text: "iCloud", state: .cancelled), nil) == "c\t[-]\tiCloud")
}
