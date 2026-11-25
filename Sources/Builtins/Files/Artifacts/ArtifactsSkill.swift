import Core
import KelpKit

extension Builtins {
    /// The `kelp artifact` skill for agents: where a doc, a review or a plan goes, and how. It is always written; the
    /// daemon decides which chats get it (the `agents.skills.artifacts` setting).
    static let artifactsSkill = SkillSpec(
        name: "kelp-artifacts",
        description:
            "Use when the user asks for a doc, report or plan, choices to pick from, slides, a design, a dashboard, "
            + "a video or proof that a change works, in Kelp, the IDE this session runs in: run kelp artifact guide "
            + "<type> first. It says where to make it (your own artifact tools come first) and how.",
        body: """
            # Docs, reviews and other pages in Kelp

            This session runs inside Kelp and the `kelp` CLI is on PATH. For a page the user reads more than once or
            decides on (a doc, a report, a plan, choices to pick from, slides, a design, a dashboard, a video), run
            `kelp artifact guide <doc|review|slides|design|dashboard|motion|proof>` first and follow it: it says
            whether to make it with your own artifact tools or in the project, and the rules for that kind. A short
            answer stays in the chat.

            - `kelp artifact new <doc|review|slides|design|dashboard|motion|proof> "<title>"` — a page in the project's
              `.kelp/artifacts`, opened beside you; prints the file to write. Write it with your file tools; the tab
              follows.
            - A `proof` is for a change you made: what you ran and the pictures of it, before and after, for the user
              to look at before they commit. Make one when they ask you to show that it works, or the project's
              instructions ask.
            - `kelp artifact check <name>` — what Kelp finds wrong on a page it drew (text cut off, contrast,
              sizes, missing files), as text: run it once instead of a screenshot.
            - `kelp artifact list`, `kelp artifact open <name>` — the project's pages, yours and other agents'.
              `--all --json` lists every project's, with tags, archive and whether a page waits for the user; you
              change only this project's.
            - Tag a page you make with what it is about: run `kelp artifact tags` first and reuse a tag that exists
              rather than a new spelling, then `kelp artifact tag <name> +<tag>`.
            - When the user asks you to put pages in order, don't change anything first: make a review page
              (`kelp artifact guide review`) that proposes what to archive and how to tag, and do only what they
              pick, with `kelp artifact tag|untag|archive`. You can't delete pages; the user can undo what you did.
            - A page you publish with claude-artifacts or Claude Docs joins that list by itself; give the user its
              link, which opens in their own browser (Kelp's tabs aren't signed in to claude.ai).

            """
    )
}
