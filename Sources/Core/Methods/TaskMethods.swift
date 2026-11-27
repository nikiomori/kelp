import Foundation

// The methods behind the Tasks tab, the panel's Tasks source and `kelp task`. A project's tasks are `- [ ]` lines on
// its pages in `.kelp/artifacts` of the project's own folder (never a branch's copy), and the daemon writes those lines
// itself, so the tab, the CLI and agents can't lose each other's change.

/// One page's task lines, as the Tasks tab lists them.
public struct TaskPage: Codable, Equatable, Sendable {
    /// The page's file.
    public var path: String
    /// The page's folder name in `.kelp/artifacts`, and its title.
    public var slug: String, title: String
    /// When the file was last saved, seconds since 1970.
    public var modified: Double?
    public var tasks: [TaskLine]
    /// True for the project's own list (`Tasks · <project>`), where Quick Entry writes.
    public var isList: Bool?
    /// The page's `##` headings in order; on the project's list the first is its inbox.
    public var sections: [String]?
    public var inbox: String? { isList == true ? sections?.first : nil }
    /// What "done" means for the task this page grew from (its **Done when:** line, `TaskLines.goal`).
    public var goal: String?
    public init(
        path: String, slug: String, title: String, modified: Double? = nil, tasks: [TaskLine], isList: Bool? = nil,
        sections: [String]? = nil, goal: String? = nil
    ) {
        self.path = path
        self.slug = slug
        self.title = title
        self.modified = modified
        self.tasks = tasks
        self.isList = isList
        self.sections = sections
        self.goal = goal
    }
}

/// A watched project's task pages (`WatchTopic.tasks`), read again when its `.kelp/artifacts` changes: the project's
/// list first, then the other pages with tasks, the latest changed first. `error` says why they couldn't be read.
public struct TasksEvent: RPCEvent, Equatable {
    public static let name = "event.tasks"
    public var repo: String
    public var pages: [TaskPage]
    public var error: String?
    public init(repo: String, pages: [TaskPage], error: String? = nil) {
        self.repo = repo
        self.pages = pages
        self.error = error
    }
}

/// The task pages of the project `repoId` names, or of the project that holds `cwd`, as `TasksEvent` sends them.
public struct TaskList: RPCMethod {
    public static let name = "task.list"
    public typealias Result = [TaskPage]
    public var repoId: String?, cwd: String?
    public init(repoId: String? = nil, cwd: String? = nil) {
        self.repoId = repoId
        self.cwd = cwd
    }
}

/// What the project's list is called when a first task makes it: its title and its first heading (the inbox), in
/// the words of the one who writes (the window's language; English from the CLI).
public struct TaskListNames: Codable, Equatable, Sendable {
    public var title: String, inbox: String
    public init(title: String, inbox: String) {
        self.title = title
        self.inbox = inbox
    }
    public static let english = TaskListNames(title: "Tasks", inbox: "Inbox")
}

/// Adds a task line. It goes on the page `path` names, or on the project's list (made with `names` if there is none
/// yet), as the last line under the heading `under`, or under the first heading. The project is `repoId`, or the one
/// that holds `cwd`. A line from an agent's program is `proposed`, whatever the call says, and an agent may propose at
/// most `TaskAdd.proposalsPerTurn` lines a turn. `chat` links a chat started for the task; `issue` is the issue it came
/// from (a line with that issue already gets the chat instead of a second line). Returns the page and the line written.
public struct TaskAdd: RPCMethod {
    public static let name = "task.add"
    public static let proposalsPerTurn = 3
    public struct Result: Codable, Equatable, Sendable {
        public var path: String, task: TaskLine
        public init(path: String, task: TaskLine) {
            self.path = path
            self.task = task
        }
    }
    public var repoId: String?, cwd: String?, path: String?, under: String?
    public var text: String
    public var issue: String?, chat: String?
    public var names: TaskListNames?
    public init(
        repoId: String? = nil, cwd: String? = nil, path: String? = nil, under: String? = nil, text: String,
        issue: String? = nil, chat: String? = nil, names: TaskListNames? = nil
    ) {
        self.repoId = repoId
        self.cwd = cwd
        self.path = path
        self.under = under
        self.text = text
        self.issue = issue
        self.chat = chat
        self.names = names
    }
}

/// Changes the task `task` names on the page `path`: its `state`, taking an agent's proposal (`accept`), adding a
/// `chat` started for it, or removing the line (`remove`; refused while chats are linked). Only the person closes or
/// cancels a task line: an agent's program may tick the steps under one (an indented line), and cancel what it
/// proposed.
/// `grow` makes the line a page of its own (the person's alone): a page titled with the line's words, a **Done when:**
/// line in `goalLabel`'s words, a heading named `grow` for its plan, and the line becomes a link to it.
/// `move` takes the line, with its id and chats, to the page of that file (the same one too), as the last line under
/// the heading `under` (its first heading when nil); the person's alone.
/// Returns the line as written, or nil once removed.
public struct TaskChange: RPCMethod {
    public static let name = "task.change"
    public typealias Result = TaskLine?
    public var path: String, task: TaskRef
    public var state: TaskState?, accept: Bool?, chat: String?, remove: Bool?, grow: String?, goalLabel: String?
    public var move: String?, under: String?
    public init(
        path: String, task: TaskRef, state: TaskState? = nil, accept: Bool? = nil, chat: String? = nil,
        remove: Bool? = nil, grow: String? = nil, goalLabel: String? = nil, move: String? = nil, under: String? = nil
    ) {
        self.path = path
        self.task = task
        self.state = state
        self.accept = accept
        self.chat = chat
        self.remove = remove
        self.grow = grow
        self.goalLabel = goalLabel
        self.move = move
        self.under = under
    }
}
