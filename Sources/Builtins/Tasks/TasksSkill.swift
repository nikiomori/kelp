import Core
import KelpKit

extension Builtins {
    /// The `kelp task` skill, for agents: how the person's tasks are kept, how to tick the steps of the one a chat was
    /// started for, and how to propose more without taking the person's decisions.
    static let tasksSkill = SkillSpec(
        name: "kelp-tasks",
        description:
            "Use when you were started on a task from the person's task list ($KELP_TASK is set), when you finish a "
            + "step of a plan written as - [ ] lines on a page of Kelp's, or when you find more work worth doing, in "
            + "Kelp, the IDE this session runs in: kelp task show|done|add.",
        setting: SettingKeys.skillTasks,
        body: """
            # Tasks in Kelp

            This session runs inside Kelp and the `kelp` CLI is on PATH. The person's tasks are `- [ ]` lines on the
            project's pages in `.kelp/artifacts` (the project's own list is `tasks/doc.md`); a page's plan is the same
            kind of lines. Kelp gathers them in its Tasks tab and works out what each one's chats are doing.

            - Started for a task, `$KELP_TASK` holds its id: `kelp task show $KELP_TASK` prints it, the issue it came
              from and, for a task that grew into a page, that page's steps with their ids.
            - When a step is done, `kelp task done <id>` ticks it (a line with no id yet is named `page:line`, as
              `kelp task list` prints it). You may also edit the page's lines as text.
            - The task line itself is the person's to close or cancel: Kelp refuses it from you. Say what's left
              to check instead.
            - Found more work worth doing? `kelp task add "<words>"` writes it to the person's inbox as a proposal
              they take or not. At most three a turn: past that, ask the person.
            - `kelp task list [--all] [--json]` prints the open tasks (and the done ones with `--all`).
            """)
}
