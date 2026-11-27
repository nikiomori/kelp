import Core
import Foundation
import Testing

@testable import KelpKit

private func chat(_ status: AgentStatus) -> Session {
    var s = Session(cwd: "/tmp", command: "claude")
    s.agent = "claude"
    s.status = status
    return s
}

/// A task's work is the most urgent of its chats': a question beats a failure, which beats work, which beats work done.
@Test(arguments: [
    ([AgentStatus](), TaskWork.none), ([.done], .review), ([.idle, .exited], .review), ([.done, .working], .working),
    ([.paused], .working), ([.working, .error], .failed), ([.error, .waiting, .working], .asks)
])
func aTasksWorkIsItsMostUrgentChats(statuses: [AgentStatus], work: TaskWork) {
    #expect(TaskWork.of(statuses.map(chat)) == work)
}

private let list = TaskPage(
    path: "/p/.kelp/artifacts/tasks/doc.md", slug: "tasks", title: "Tasks · kelp",
    tasks: [
        TaskLine(id: "a", text: "Dark diff #design", line: 4, section: "Inbox"),
        TaskLine(id: "b", text: "Fix the inset", line: 7, section: "Now", chats: ["working"]),
        TaskLine(id: "c", text: "a step under it", line: 8, depth: 1, section: "Now"),
        TaskLine(id: "d", text: "Ru strings", line: 9, section: "Now", chats: ["done"]),
        TaskLine(id: "e", text: "Squeeze", line: 5, section: "Inbox", proposed: true, by: "s", at: 10),
        TaskLine(id: "f", text: "Ollama", state: .done, line: 12, section: "Later", at: 1_800_000_000),
        TaskLine(id: "g", text: "iCloud", state: .cancelled, line: 13, section: "Later", at: 1_700_000_000),
        TaskLine(id: "h", text: "Asks", line: 10, section: "Now", chats: ["asks"])
    ], isList: true, sections: ["Inbox", "Now", "Later"])
private let plan = TaskPage(
    path: "/p/.kelp/artifacts/search/doc.md", slug: "search", title: "Search chats",
    tasks: [TaskLine(id: "s1", text: "Index transcripts", line: 5, section: "Plan")])

private let rows: [TaskRow] = {
    let chats = ["working": chat(.working), "done": chat(.done), "asks": chat(.waiting)]
    return TaskViews.rows([("kelp", [list, plan])], session: { chats[$0] })
}()

/// Each list holds what it says: the inbox the list's first heading, Now what an agent touches or waits on, Waiting
/// for You the person's turn (a question, work to review, a proposal), All every open task (no steps set in under
/// one), the logbook what was closed or cancelled.
@Test(arguments: [
    (TaskSource.inbox, ["a", "e"]), (.now, ["b", "d", "e", "h"]), (.waiting, ["d", "e", "h"]),
    (.all, ["a", "b", "d", "e", "h", "s1"]), (.journal, ["f", "g"]),
    (.project("kelp"), ["a", "b", "d", "e", "h", "s1"]),
    (.project("other"), []), (.tag("design"), ["a"])
])
func eachListHoldsItsTasks(source: TaskSource, ids: [String]) {
    #expect(rows.filter(source.holds).compactMap(\.task.id).sorted() == ids)
}

/// Now puts the person's turn first; the logbook groups by day, newest first; the other lists by project and place,
/// and search reads words and `#tags`.
@Test func listsComeInGroups() {
    let now = TaskViews.sections(rows, .now, day: { _ in "" })
    #expect(now.map(\.title) == ["Waiting for You", "Working"])
    #expect(now[0].rows.compactMap(\.task.id) == ["d", "e", "h"] && now[1].rows.compactMap(\.task.id) == ["b"])

    let log = TaskViews.sections(rows, .journal, day: { $0 > 1_750_000_000 ? "Recent" : "Earlier" })
    #expect(log.map(\.title) == ["Recent", "Earlier"])

    let all = TaskViews.sections(rows, .all, projectName: { $0.uppercased() }, day: { _ in "" })
    #expect(all.map(\.title) == ["KELP › Inbox", "KELP › Now", "KELP › Search chats › Plan"])
    #expect(
        TaskViews.sections(rows, .all, find: "#design", day: { _ in "" }).flatMap(\.rows).compactMap(\.task.id) == ["a"]
    )
    #expect(
        TaskViews.sections(rows, .all, find: "search", day: { _ in "" }).flatMap(\.rows).compactMap(\.task.id) == ["s1"]
    )
}

@Test func countsAndTagsFollowTheRows() {
    let counts = TaskViews.counts(rows, [.inbox, .waiting, .journal])
    #expect(counts == [.inbox: 2, .waiting: 3, .journal: 2])
    #expect(TaskViews.tags(rows) == ["design"])
}

/// The board puts each task in one column, worked out from its chats, its page and its PR: a question first in its
/// column; Done holds only what closed in the last week.
@Test func theBoardsColumnsAreWorkedOut() {
    var grown = TaskLine(id: "p", text: "[Search](../s/doc.md)", line: 20, section: "Now")
    grown.chats = nil
    let page = TaskPage(
        path: list.path, slug: "tasks", title: list.title, tasks: list.tasks + [grown], isList: true,
        sections: list.sections)
    let chats = ["working": chat(.working), "done": chat(.done), "asks": chat(.waiting)]
    let all = TaskViews.rows([("kelp", [page])], session: { chats[$0] })
    let board = TaskViews.board(all, .all, inPR: { $0.task.id == "d" }, now: Date(timeIntervalSince1970: 1_800_100_000))
    let ids = Dictionary(uniqueKeysWithValues: board.map { ($0.column, $0.rows.compactMap(\.task.id)) })
    #expect(ids[.ideas] == ["a", "e"])
    #expect(ids[.plan] == ["p"])
    #expect(ids[.working] == ["h", "b"])
    #expect(ids[.review] == [])
    #expect(ids[.pullRequest] == ["d"])
    #expect(ids[.done] == ["f"])
}

/// The agent is told the task, where it is and how to tick its steps; a grown page's goal becomes Claude Code's /goal,
/// on one line, and is said in words to another agent.
@MainActor @Test func anAgentIsBriefedOnItsTask() {
    let task = TaskLine(id: "7f3a", text: "[Search](../s/doc.md)", line: 4)
    let plain = TaskActions.brief(task, list)
    #expect(plain.hasPrefix("Search\n") && plain.contains("kelp task show 7f3a") && plain.contains("line 4"))
    let slash = TaskActions.brief(task, list, goal: "finds in 200 ms", slash: true)
    #expect(slash.hasPrefix("/goal finds in 200 ms — Search ") && !slash.contains("\n"))
    #expect(TaskActions.brief(task, list, goal: "finds in 200 ms").hasSuffix("Done when: finds in 200 ms"))
}
