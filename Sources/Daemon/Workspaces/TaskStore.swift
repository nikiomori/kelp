import Core
import Foundation

/// A project's tasks on disk: the `- [ ]` lines of its Markdown pages in `.kelp/artifacts` of the project's own folder,
/// with the project's list (`tasks/doc.md`, "Tasks · <project>") first. One copy per project: a chat on a branch of its
/// own writes here through `kelp task`, never into its branch's copy, and the folder stays out of git as the artifacts
/// do.
enum TaskStore {
    /// The folder of the project's list in `.kelp/artifacts`.
    static let listSlug = "tasks"

    /// The project `repoId` names, or the one whose workspace holds `cwd`.
    static func repo(_ store: Store, repoId: String?, cwd: String?) throws -> Repo {
        if let repoId, let repo = try store.repo(repoId) { return repo }
        if let cwd, let worktree = IDE.workspace(cwd: cwd, among: try store.worktrees(), own: nil),
            let repo = try store.repo(worktree.repoId)
        {
            return repo
        }
        throw RPCError.invalidParams("no project holds \(cwd ?? repoId ?? "this folder")")
    }

    /// Every page of the project at `root` that has task lines, and its list even when empty.
    static func pages(root: String) -> [TaskPage] {
        let base = Artifacts.dir(root: root), fm = FileManager.default
        var pages: [TaskPage] = []
        for (slug, record) in Artifacts.list(root: root) {
            guard let file = record.file, file.hasSuffix(".md") else { continue }
            let path = base.appendingPathComponent(slug).appendingPathComponent(file).path
            guard let data = fm.contents(atPath: path) else { continue }
            let text = String(decoding: data, as: UTF8.self), tasks = TaskLines.parse(text)
            let isList = slug == listSlug, goal = TaskLines.goal(text)
            guard isList || !tasks.isEmpty || goal != nil else { continue }
            let modified = fm.modified(path).map { $0.timeIntervalSince1970.rounded(.down) }
            pages.append(
                TaskPage(
                    path: path, slug: slug, title: record.title, modified: modified, tasks: tasks,
                    isList: isList ? true : nil, sections: isList ? TaskLines.sections(text) : nil, goal: goal))
        }
        return pages.sorted { a, b in
            a.isList != b.isList ? a.isList == true : (a.modified ?? 0) > (b.modified ?? 0)
        }
    }

    /// The project's list at `root`, made with `names` when there is none.
    static func list(root: String, names: TaskListNames, project: String, now: Date = Date()) throws -> String {
        let base = Artifacts.dir(root: root), fm = FileManager.default
        let folder = base.appendingPathComponent(listSlug)
        if let record = Artifacts.record(in: folder), let file = record.file {
            return folder.appendingPathComponent(file).path
        }
        if !fm.fileExists(atPath: base.path) {
            try Artifacts.excludeFromGit(root: root)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let kind = Artifacts.Kind.doc, title = "\(names.title) · \(project)"
        let page = folder.appendingPathComponent(kind.file)
        try "# \(title)\n\n## \(names.inbox)\n".write(to: page, atomically: true, encoding: .utf8)
        try Artifacts.save(ArtifactRecord(type: kind.rawValue, title: title, created: now, file: kind.file), in: folder)
        return page.path
    }

    /// The text of a task page, refusing a file that isn't a Markdown page in `.kelp/artifacts`.
    static func read(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "md", url.path.contains("/\(Artifacts.folder)/"),
            let data = FileManager.default.contents(atPath: url.path)
        else { throw RPCError.invalidParams("not a page in .kelp/artifacts: \(path)") }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Refuses `agent` a page outside the tasks of the project it works in. The list sits in the project's own folder,
    /// so a chat on a branch of its own reaches it, though the folder isn't its workspace's.
    static func ensureOwn(_ store: Store, agent: String, path: String) throws {
        let own = try store.session(agent)?.worktreeId.flatMap { try store.worktree($0) }
        guard let own, let repo = try store.repo(own.repoId),
            URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(Artifacts.dir(root: repo.path).path + "/")
        else { throw RPCError.refused("an agent changes only the tasks of the project it works in") }
    }

    /// The watch of a project's tasks (`WatchTopic.tasks`): read when the `.kelp/artifacts` of the project's own folder
    /// changes. `line` makes the event's line.
    static func topic(_ key: String, _ store: Store, _ line: @escaping @Sendable (TasksEvent) -> Data?)
        -> Watches.Topic
    {
        let root = store.look("project \(key)") { try $0.repo(key) }?.path
        let matters: @Sendable ([FileWatcher.Change]) -> Bool = {
            $0.contains { $0.path.contains("/\(Artifacts.folder)/") }
        }
        return Watches.Topic(folder: root.map { ($0, matters) }) { _ in
            (line(TasksEvent(repo: key, pages: root.map(pages) ?? [])), nil)
        }
    }

    /// The agent's session behind this call, or nil when the person makes it (their terminal, Kelp's window). A program
    /// Kelp can't place counts as an agent's.
    static func agent(_ store: Store) throws -> String? {
        guard let asker = Sessions.asker, try store.forAnAgent(asker) else { return nil }
        return asker
    }
}

extension TaskList: Handled {
    static let agents = AgentAccess.reads
    func handle(_ store: Store) throws -> [TaskPage] {
        TaskStore.pages(root: try TaskStore.repo(store, repoId: repoId, cwd: cwd).path)
    }
}

extension TaskAdd: Handled {
    static let agents = AgentAccess.acts
    var fence: Fence { Fence(writesInFolder: cwd ?? path.map { ($0 as NSString).deletingLastPathComponent }) }

    func handle(_ store: Store) throws -> Result {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !words.isEmpty else { throw RPCError.invalidParams("a task needs words") }
        let repo = try TaskStore.repo(store, repoId: repoId, cwd: cwd)
        let pages = TaskStore.pages(root: repo.path)
        // A line for this issue already: the chat joins it.
        if let issue, let page = pages.first(where: { $0.tasks.contains { $0.issue == issue } }),
            let known = page.tasks.first(where: { $0.issue == issue })
        {
            let (text, task) = try TaskLines.change(try TaskStore.read(page.path), TaskRef(known)) { line in
                if let chat, !(line.chats ?? []).contains(chat) { line.chats = (line.chats ?? []) + [chat] }
            }
            try TaskStore.write(text, to: page.path)
            return Result(path: page.path, task: task)
        }
        let now = Date()
        var task = TaskLine(text: words, issue: issue)
        task.id = TaskLines.newId(taken: Set(pages.flatMap { $0.tasks.compactMap(\.id) }))
        if let chat { task.chats = [chat] }
        if let agent = try TaskStore.agent(store) {
            // The turn began when the chat last changed state; a line keeps whole seconds.
            let since = (try store.session(agent)?.statusAt?.timeIntervalSince1970 ?? 0).rounded(.down)
            let made = pages.flatMap(\.tasks).count { $0.by == agent && ($0.at ?? 0) >= since }
            guard made < Self.proposalsPerTurn else {
                throw RPCError.refused(
                    "\(Self.proposalsPerTurn) proposals per turn: ask the person instead of proposing more")
            }
            task.proposed = true
            task.by = agent
            task.at = now.timeIntervalSince1970
        }
        let names = names ?? .english
        if let path, let agent = try TaskStore.agent(store) { try TaskStore.ensureOwn(store, agent: agent, path: path) }
        let page = try path ?? TaskStore.list(root: repo.path, names: names, project: repo.name, now: now)
        let (text, line) = TaskLines.add(task, under: under, to: try TaskStore.read(page), newSection: names.inbox)
        try TaskStore.write(text, to: page)
        task.line = line
        return Result(path: page, task: TaskLines.parse(text).first { $0.id == task.id } ?? task)
    }
}

/// No folder fence: an agent on a branch of its own ticks the steps on its project's list, in the project's own folder.
/// The handler holds an agent to its own project's pages instead (`TaskStore.ensureOwn`).
extension TaskChange: Handled {
    static let agents = AgentAccess.acts

    func handle(_ store: Store) throws -> TaskLine? {
        let text = try TaskStore.read(path)
        let lines = text.components(separatedBy: "\n")
        let index = try TaskLines.index(of: task, in: lines)
        guard let current = TaskLines.line(lines[index]) else { throw TaskLines.Failure.noTask(task) }
        let agent = try TaskStore.agent(store)
        if let agent { try TaskStore.ensureOwn(store, agent: agent, path: path) }
        let own = agent != nil && current.by == agent && current.proposed == true
        if agent != nil {
            if grow != nil { throw RPCError.refused("only the person makes a task a page") }
            if move != nil { throw RPCError.refused("only the person moves a task") }
            if accept == true { throw RPCError.refused("only the person takes a proposed task") }
            if remove == true, !own { throw RPCError.refused("an agent removes only the tasks it proposed") }
            if let state, current.depth == 0, !(own && state == .cancelled) {
                throw RPCError.refused("a task line is closed by the person; mark the steps under it")
            }
        }
        if let move {
            // Out of this page, into the other (or into another heading of this one), as written, set in no further.
            var line = current
            line.depth = 0
            let source = try TaskLines.remove(text, task)
            try TaskStore.write(source, to: path)
            let target = move == path ? source : try TaskStore.read(move)
            let (moved, at) = TaskLines.add(line, under: under, to: target, newSection: under ?? "Inbox")
            try TaskStore.write(moved, to: move)
            line.line = at
            line.section = under ?? TaskLines.sections(moved).first
            return line
        }
        if remove == true {
            guard (current.chats ?? []).isEmpty else {
                throw RPCError.refused("the task has chats: cancel it instead of removing it")
            }
            try TaskStore.write(try TaskLines.remove(text, task), to: path)
            return nil
        }
        let now = Date().timeIntervalSince1970
        // A page of its own, beside the list in .kelp/artifacts, linked from the line.
        var link: String?
        if let plan = grow, current.page == nil, let at = path.range(of: "/\(Artifacts.folder)/") {
            let root = String(path[..<at.lowerBound]), title = current.title
            let page = try Artifacts.create(.doc, title: title, root: root, session: nil)
            let goal = goalLabel.map { "**\($0):** \n\n" } ?? ""
            try "# \(title)\n\n\(goal)## \(plan)\n".write(to: page, atomically: true, encoding: .utf8)
            let words = title.replacingOccurrences(of: "]", with: ")")
            link = "[\(words)](../\(page.deletingLastPathComponent().lastPathComponent)/\(page.lastPathComponent))"
        }
        let (next, line) = try TaskLines.change(text, task) { line in
            if let link { line.text = link }
            if accept == true {
                line.proposed = nil
                line.by = nil
                line.at = nil
            }
            if let state, state != line.state {
                line.state = state
                if line.proposed != true { line.at = state == .open ? nil : now }
            }
            if let chat, !(line.chats ?? []).contains(chat) { line.chats = (line.chats ?? []) + [chat] }
        }
        if next != text { try TaskStore.write(next, to: path) }
        return line
    }
}

extension Methods {
    static let taskMethods: [any Answered.Type] = [TaskList.self, TaskAdd.self, TaskChange.self]
}
