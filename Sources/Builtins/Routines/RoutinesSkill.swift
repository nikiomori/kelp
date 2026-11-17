import Core
import KelpKit

extension Builtins {
    /// `kelp routine add`, for agents: the user asks a chat for work on a schedule, and allows what it adds.
    static let routinesSkill = SkillSpec(
        name: "kelp-routines",
        description:
            "Use when the user asks for a routine, or for work on a schedule (every morning, hourly, each Monday), "
            + "in Kelp, the IDE this session runs in: kelp routine add makes one, an agent Kelp starts with your "
            + "prompt at each time, on this Mac in this project, once the user allows it on your row.",
        setting: SettingKeys.skillRoutines,
        body: """
            # Routines in Kelp

            This session runs inside Kelp and the `kelp` CLI is on PATH. A routine is an agent on a schedule: at
            each time Kelp starts the agent with the routine's prompt, in a workspace of the routine's own in this
            project's folder, and keeps how each run went in the project's Routines tab. It runs on this Mac while
            Kelp does: one missed while the Mac slept runs once when it wakes. For work that must run with the Mac
            off, say so and offer what does (a cloud routine, CI).

            - `kelp routine add "Morning triage" --prompt "…" --every weekdays --at 9:00` adds one in this project
              and prints it. `--every hourly|daily|weekdays|weekly` (weekdays unless you say); `--at` is the Mac's
              time, 24-hour (`9:00`; hourly: the minute, `:15`); `--day mon` picks a weekly one's day; `--agent
              codex` and `--model m` pick who runs it (Claude Code unless you say); `--skip-missed` drops a missed
              run instead of running it late.
            - Kelp asks the user on your row first, with the name, the prompt, the agent and the times, and your
              command waits for their answer, up to ten minutes: run it with your shell tool's longest timeout
              (Claude Code's Bash: `timeout: 600000`). Denied, it fails: don't run it again, ask the user what
              they'd change.
            - The user reads all of it before allowing: the name takes up to 40 characters, the prompt up to 200. A
              longer task goes in a file of the project (`docs/triage.md`) that the prompt names.
            - The prompt is all the run's agent knows: it starts with nothing of this chat. Say what to look at,
              what to do and what to leave behind (a comment, a branch, a summary: a run's first line shows in the
              Routines tab).
            - Nobody sits at a run: where its agent asks a permission, it waits until the user sees it. Ask for work
              the agent may do unasked, or tell the user what it will ask for.
            - `kelp routine list` prints the routines and their runs of the last two weeks, as JSON.
            - Changing, running now and deleting a routine are the user's, in the Routines tab ("+" at the end of
              the tabs): tell them which one, and don't work around it with cron or launchd.

            Add a routine only when the user asked for one, and once: then say what you added and when it first
            runs.

            """
    )
}
