import AppKit
import Core

/// What a list of tasks outside the Tasks built-in (the Issues panel's Tasks source, a page's task lines) does with a
/// task, as the Tasks tab does: its row, its menu, opening its page and handing it to an agent. The Tasks built-in
/// provides it.
@MainActor
package struct ListedTasks {
    /// The Tasks tab's row for `row`, with `place` under its words; `fill` adds the list's own items to its menu.
    package let cell: (_ row: TaskRow, _ place: String, _ fill: ((NSMenu) -> Void)?) -> NSView
    /// The task's menu, the same in every list.
    package let fill: (_ menu: NSMenu, _ row: TaskRow) -> Void
    /// Opens the page the task grew into, or the page it is on at its line.
    package let open: (_ row: TaskRow) -> Void
    /// Starts the agent the last task went to on the task.
    package let run: (_ row: TaskRow) -> Void
    /// The agent the last task went to, offered first.
    package let lastAgent: () -> String

    package init(
        cell: @escaping (TaskRow, String, ((NSMenu) -> Void)?) -> NSView, fill: @escaping (NSMenu, TaskRow) -> Void,
        open: @escaping (TaskRow) -> Void, run: @escaping (TaskRow) -> Void, lastAgent: @escaping () -> String
    ) {
        self.cell = cell
        self.fill = fill
        self.open = open
        self.run = run
        self.lastAgent = lastAgent
    }
}
