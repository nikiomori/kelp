import Core
import KelpKit

extension Builtins {
    /// `kelp artifact`, for agents: where a doc, a review or a plan goes, and how. Always written: which chats get it
    /// is the daemon's choice (Settings' `agents.skills.artifacts`).
    static let artifactsSkill = SkillSpec(
        name: "kelp-artifacts",
        description:
            "Use when the user asks for a doc, report or plan, choices to pick from, slides, a design, a dashboard or proof "
            + "that a change works, in Kelp, the IDE this session runs in: run kelp artifact guide <type> first. It says "
            + "where to make it (your own artifact tools come first) and how.",
        body: """
            # Docs, reviews and other pages in Kelp

            This session runs inside Kelp and the `kelp` CLI is on PATH. For a page the user reads more than once or
            decides on (a doc, a report, a plan, choices to pick from, slides, a design, a dashboard), run
            `kelp artifact guide <doc|review|slides|design|dashboard|proof>` first and follow it: it says whether to
            make it with your own artifact tools or in the project, and the rules for that kind. A short answer stays
            in the chat.

            - `kelp artifact new <doc|review|slides|design|dashboard|proof> "<title>"` — a page in the project's
              `.kelp/artifacts`, opened beside you; prints the file to write. Write it with your file tools; the tab
              follows.
            - A `proof` is for a change you made: what you ran and the pictures of it, before and after, for the user
              to look at before they commit. Make one when they ask you to show that it works, or the project's
              instructions ask.
            - `kelp artifact check <name>` — what Kelp finds wrong on a design it drew (text cut off, contrast,
              sizes), as text: run it once instead of a screenshot.
            - `kelp artifact list`, `kelp artifact open <name>` — the project's pages, yours and other agents'.
            - A page you publish with claude-artifacts or Claude Docs joins that list by itself; give the user its
              link, which opens in their own browser (Kelp's tabs aren't signed in to claude.ai).

            """
    )
}
