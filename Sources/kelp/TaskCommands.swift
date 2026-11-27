import Core
import Foundation

/// `kelp task list|show|add|done|reopen|cancel`: the project's tasks, `- [ ]` lines on its pages in .kelp/artifacts. An
/// agent's `add` is a proposal the person takes or not (three a turn at most), and only the person closes a task line:
/// an agent ticks the steps under one.
extension Main {
    static func tasks(_ sub: String?, _ client: RPCClient) async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let pages = { try await client.call(TaskList(cwd: cwd)) }
        switch sub {
        case "list":
            let every = has("--all"), json = has("--json")
            let listed = try await pages().map { page in
                var page = page
                page.tasks = page.tasks.filter { every || $0.state == .open }
                return page
            }
            if json {
                show(listed)
                return
            }
            let lines = listed.flatMap { page in page.tasks.map { Self.row($0, page) } }
            print(lines.isEmpty ? "No open tasks." : lines.joined(separator: "\n"))
        case "show":
            let (task, page) = try await find(try await pages())
            print(Self.row(task, page))
            if let issue = task.issue { print("issue: \(issue)") }
            if let chats = task.chats { print("chats: \(chats.joined(separator: " "))") }
            if let linked = task.page {
                let path = URL(fileURLWithPath: page.path).deletingLastPathComponent().appendingPathComponent(linked)
                    .standardizedFileURL.path
                print("page: \(path)")
                if let steps = try await pages().first(where: { $0.path == path })?.tasks {
                    for step in steps { print("  " + Self.row(step, nil)) }
                }
            }
        case "add":
            let page = flag("--page"), under = flag("--under"), issue = flag("--issue")
            guard let text = args.first, !text.hasPrefix("-") else {
                fail("task add \"<words>\" [--page <name>] [--under <heading>] [--issue <url>]")
            }
            var path: String?
            if let page {
                guard let found = try await pages().first(where: { $0.slug == page || $0.path == page }) else {
                    fail("no page \(page) with tasks (see kelp task list)")
                }
                path = found.path
            }
            let made = try await client.call(TaskAdd(cwd: cwd, path: path, under: under, text: text, issue: issue))
            let word = made.task.proposed == true ? "proposed" : "added"
            print("\(word) \(made.task.id ?? "") → \(made.task.section ?? (made.path as NSString).lastPathComponent)")
        case "done", "reopen", "cancel":
            let (task, page) = try await find(try await pages())
            let state: TaskState = sub == "done" ? .done : sub == "reopen" ? .open : .cancelled
            let line = try await client.call(TaskChange(path: page.path, task: TaskRef(task), state: state))
            print("\(sub == "reopen" ? "reopened" : sub == "done" ? "done" : "cancelled") \(line?.id ?? "")")
        default: print(usage)
        }
    }

    /// The task the first argument names by its id (or the start of one), and its page.
    private static func find(_ pages: [TaskPage]) async throws -> (TaskLine, TaskPage) {
        guard let prefix = args.first, !prefix.isEmpty else { fail("a task's id required (see `kelp task list`)") }
        // A line with no id yet is named by its page and line: tasks:12.
        if let colon = prefix.lastIndex(of: ":"), let n = Int(prefix[prefix.index(after: colon)...]),
            let page = pages.first(where: { $0.slug == prefix[..<colon] }),
            let task = page.tasks.first(where: { $0.line == n })
        {
            return (task, page)
        }
        let id = unique(prefix, among: pages.flatMap { $0.tasks.compactMap(\.id) })
        for page in pages { if let task = page.tasks.first(where: { $0.id == id }) { return (task, page) } }
        fail("no task \(prefix)")
    }

    /// One task as a line of `list`: id, box, words, and where it is.
    static func row(_ task: TaskLine, _ page: TaskPage?) -> String {
        let box = task.state == .open ? (task.proposed == true ? "( )" : "[ ]") : task.state == .done ? "[x]" : "[-]"
        let place = page.map { [$0.slug, task.section].compactMap { $0 }.joined(separator: " › ") } ?? ""
        let name = task.id ?? page.map { "\($0.slug):\(task.line)" } ?? "-"
        return [name, box, task.title, place].filter { !$0.isEmpty }.joined(separator: "\t")
    }
}
