import Core
import Foundation
import Testing

@testable import Daemon

/// A project and an agent's chat in a fresh store, with the project's folder on disk.
private func project() throws -> (store: Store, repo: Repo, agent: Session, root: URL) {
    let store = try Store()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = try store.save(Repo(name: "kelp", path: root.path))
    // The agent works on a branch of its own, in another folder: the project's list is still its to tick.
    let branch = try store.save(
        Worktree(repoId: repo.id, branch: "kelp/search", path: root.path + "-search", note: ""))
    var agent = Session(cwd: branch.path, command: "claude")
    agent.agent = "claude"
    agent.worktreeId = branch.id
    return (store, repo, try store.save(agent), root)
}

/// The person's first task makes the project's list, in the window's words, and goes under its inbox; the list is the
/// first page the project reads, and stays out of git as artifacts do.
@Test func theFirstTaskMakesTheProjectsList() throws {
    let p = try project()
    defer { try? FileManager.default.removeItem(at: p.root) }
    let names = TaskListNames(title: "Задачи", inbox: "Входящие")
    let made = try TaskAdd(repoId: p.repo.id, text: " Dark diff \n", names: names).handle(p.store)
    #expect(made.path.hasSuffix("/.kelp/artifacts/tasks/doc.md"))
    #expect(made.task.text == "Dark diff" && made.task.id != nil && made.task.proposed == nil)
    let text = try String(contentsOfFile: made.path, encoding: .utf8)
    #expect(text.hasPrefix("# Задачи · kelp\n\n## Входящие\n- [ ] Dark diff <!-- k:"))
    let pages = try TaskList(repoId: p.repo.id).handle(p.store)
    #expect(pages.first?.isList == true && pages.first?.title == "Задачи · kelp")
    #expect(pages.first?.tasks.map(\.text) == ["Dark diff"])
    #expect(throws: RPCError.self) { try TaskAdd(repoId: p.repo.id, text: "  ").handle(p.store) }
}

/// An agent's line is a proposal signed with its chat, and a chat proposes at most three lines a turn.
@Test func anAgentProposesAtMostThreeATurn() async throws {
    let p = try project()
    defer { try? FileManager.default.removeItem(at: p.root) }
    try Sessions.$asker.withValue(p.agent.id) {
        for n in 1...TaskAdd.proposalsPerTurn {
            let made = try TaskAdd(repoId: p.repo.id, text: "Found \(n)").handle(p.store)
            #expect(made.task.proposed == true && made.task.by == p.agent.id)
        }
        #expect(throws: RPCError.self) { try TaskAdd(repoId: p.repo.id, text: "One more").handle(p.store) }
    }
    // The person's lines are no proposals and count for nothing.
    #expect(try TaskAdd(repoId: p.repo.id, text: "Mine").handle(p.store).task.proposed == nil)
}

/// Only the person closes or cancels a task line and takes a proposal; an agent ticks the steps under a task, and
/// cancels or removes only what it proposed. A line with chats isn't removed, only cancelled.
@Test func onlyThePersonClosesATask() throws {
    let p = try project()
    defer { try? FileManager.default.removeItem(at: p.root) }
    let task = try TaskAdd(repoId: p.repo.id, text: "Search chats").handle(p.store)
    let text = try String(contentsOfFile: task.path, encoding: .utf8) + "  - [ ] index transcripts\n"
    try text.write(toFile: task.path, atomically: true, encoding: .utf8)
    let step = try #require(TaskLines.parse(text).first { $0.depth == 1 })
    let proposed = try Sessions.$asker.withValue(p.agent.id) {
        try TaskAdd(repoId: p.repo.id, text: "Flaky test").handle(p.store).task
    }
    try Sessions.$asker.withValue(p.agent.id) {
        #expect(throws: RPCError.self) {
            try TaskChange(path: task.path, task: TaskRef(task.task), state: .done).handle(p.store)
        }
        #expect(throws: RPCError.self) {
            try TaskChange(path: task.path, task: TaskRef(proposed), accept: true).handle(p.store)
        }
        #expect(throws: RPCError.self) {
            try TaskChange(path: task.path, task: TaskRef(task.task), remove: true).handle(p.store)
        }
        let ticked = try TaskChange(path: task.path, task: TaskRef(step), state: .done).handle(p.store)
        #expect(ticked?.state == .done && ticked?.at != nil)
        #expect(
            try TaskChange(path: task.path, task: TaskRef(proposed), state: .cancelled).handle(p.store)?.state
                == .cancelled)
    }
    let chatted = try TaskChange(path: task.path, task: TaskRef(task.task), chat: "s1").handle(p.store)
    #expect(chatted?.chats == ["s1"])
    #expect(throws: RPCError.self) {
        try TaskChange(path: task.path, task: TaskRef(task.task), remove: true).handle(p.store)
    }
    #expect(try TaskChange(path: task.path, task: TaskRef(task.task), state: .done).handle(p.store)?.state == .done)
    let taken = try TaskChange(path: task.path, task: TaskRef(id: proposed.id), accept: true).handle(p.store)
    #expect(taken?.proposed == nil && taken?.by == nil)
    #expect(throws: RPCError.self) {
        try TaskChange(path: p.root.appendingPathComponent("x.md").path, task: TaskRef(id: "1")).handle(p.store)
    }
}

/// A chat started from an issue that already has a line joins that line instead of writing a second one.
@Test func anIssueHasOneLine() throws {
    let p = try project()
    defer { try? FileManager.default.removeItem(at: p.root) }
    let url = "https://github.com/o/r/issues/212"
    let first = try TaskAdd(repoId: p.repo.id, text: "Ru dates", issue: url).handle(p.store)
    let again = try TaskAdd(repoId: p.repo.id, text: "Ru dates", issue: url, chat: "s1").handle(p.store)
    #expect(again.task.id == first.task.id && again.task.chats == ["s1"])
    #expect(try TaskList(repoId: p.repo.id).handle(p.store).flatMap(\.tasks).count == 1)
}

/// An agent changes only the tasks of the project it works in.
@Test func anAgentStaysInItsProject() throws {
    let p = try project()
    defer { try? FileManager.default.removeItem(at: p.root) }
    let other = try project()
    defer { try? FileManager.default.removeItem(at: other.root) }
    let theirs = try TaskAdd(repoId: other.repo.id, text: "Theirs").handle(other.store)
    _ = try p.store.save(Repo(id: other.repo.id, name: "other", path: other.root.path))
    try Sessions.$asker.withValue(p.agent.id) {
        #expect(throws: RPCError.self) {
            try TaskChange(path: theirs.path, task: TaskRef(theirs.task), state: .done).handle(p.store)
        }
    }
}

/// A task grows into a page of its own beside the list, with a heading for its plan; the line links to it, and the
/// page's own lines are tasks too. An agent may not grow one.
@Test func aTaskGrowsIntoAPage() throws {
    let p = try project()
    defer { try? FileManager.default.removeItem(at: p.root) }
    let made = try TaskAdd(repoId: p.repo.id, text: "Search chats").handle(p.store)
    try Sessions.$asker.withValue(p.agent.id) {
        #expect(throws: RPCError.self) {
            try TaskChange(path: made.path, task: TaskRef(made.task), grow: "Plan").handle(p.store)
        }
    }
    let grown = try #require(
        try TaskChange(path: made.path, task: TaskRef(made.task), grow: "Plan", goalLabel: "Done when").handle(p.store))
    #expect(grown.title == "Search chats" && grown.id == made.task.id)
    let page = URL(fileURLWithPath: made.path).deletingLastPathComponent().appendingPathComponent(
        try #require(grown.page)
    )
    .standardizedFileURL
    #expect(try String(contentsOf: page, encoding: .utf8) == "# Search chats\n\n**Done when:** \n\n## Plan\n")
    try "# Search chats\n\n**Done when:** found in 200 ms\n\n## Plan\n".write(
        to: page, atomically: true, encoding: .utf8)
    _ = try TaskAdd(repoId: p.repo.id, path: page.path, text: "Index transcripts").handle(p.store)
    let pages = try TaskList(repoId: p.repo.id).handle(p.store)
    #expect(pages.first { $0.path == page.path }?.tasks.map(\.section) == ["Plan"])
    #expect(pages.first { $0.path == page.path }?.goal == "found in 200 ms")
}
