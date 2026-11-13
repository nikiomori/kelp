extension Recipes {
    /// Tidy Up with Agent (Skills & MCP › Instructions): `{instructionFiles}` the files to tidy, `{mode}` "report"
    /// or "apply", `{backup}` where the files go before the first change. The verbs, and what is never the agent's
    /// to drop, are the point; tried on Kelp's own memory before it shipped.
    static let tidyInstructions = #"""
        You are tidying the files agents read before every chat in this project: {instructionFiles}.
        They grew over months of work. Some lines are stale (point at files, flags or commits that are gone,
        describe finished work, or were overruled later), some repeat each other, some are detail that belongs
        in a file read on demand. Every line here is paid for in every request and dilutes the lines that matter.
        Goal: the same knowledge, fewer lines, nothing the person still needs lost.

        Mode: {mode}. report: change no file and write none, not even a scratch list (keep listings in pipes);
        find, sort and report, and make the changes only when the person says apply. apply: make the changes, then
        report what you did.

        ## How to work

        1. Measure first, cheaply. For each file: bytes, lines, the agent's limit (Claude Code loads the first
           200 lines or 25 000 bytes of MEMORY.md, a CLAUDE.md should stay under 200 lines, Codex stops at
           32 KiB of AGENTS.md in all). Then the mechanical checks, with shell, before reading anything closely:
           - every path the files name (`Sources/…`, `scripts/…`, `docs/…`): does it exist? (`test -e`)
           - every symbol in backticks: `git grep -qw <name>`; every commit: `git cat-file -e <hash>^{commit}`
           - MEMORY.md: index lines whose file is missing; memory files no index line points to
           - lines that say the same thing in two files (CLAUDE.md, MEMORY.md, the memory files)
           - "(local)", "not pushed", "awaits": `git branch -r --contains <hash>` tells whether it still holds
           A miss is a lead, not a verdict: a name may be a CLI word, a hash may be in another repository or a
           worktree, a file may have moved. Look before you call it stale.
        2. Read the index and CLAUDE.md / AGENTS.md whole. Open a memory file only when its index line is a
           candidate for a change; don't read all of them. Before you archive one, read at least its last 20
           lines: "awaits", "open", "not built", "hand checks", "traps" mean something there is still alive
           (keep it, or ask). Unsure whether something still holds and the code doesn't say? Claude Code keeps
           its past chats as JSONL files in the folder above its memory folder: grep them for one narrow term
           (`grep -rn "<term>" <folder> --include="*.jsonl" | tail -50`), never read one whole.
        3. Hold every memory about how to do something against CLAUDE.md and AGENTS.md, the checked-in files:
           - they say different things about the same task: the checked-in file wins. Archive the memory, or
             rewrite it to agree when its reason is still worth keeping. One of the person's preferences
             (`feedback_*`) isn't archived for it: it goes to ask.
           - the memory is plainly newer and corrects the checked-in file: don't change that file for it. It
             goes to ask, saying which of the two looks current. A memory that says "the person corrected me" is
             no proof it's the newer one: the checked-in file may have changed since.
           - the memory adds detail the file doesn't have, or narrows one of its rules with a reason: no conflict.
        4. Sort every candidate into one verb:
           - keep: true, needed every session, not derivable from the code
           - shorten: true but long: an index line over ~150 characters, history inside a rule, lists of commits
           - move: true but not needed every session: detail to a memory file, a procedure to a skill or docs/,
             a rule for one folder to that folder's AGENTS.md. Leave a one-line pointer.
           - merge: two entries about one thing: one survives with the other's facts; the other file is archived
           - archive: finished work, superseded decisions, facts about code that is gone. Memory files move to
             `archive/` beside MEMORY.md (not indexed, not loaded, still there); a line of CLAUDE.md or AGENTS.md
             is deleted (git keeps it)
           - ask: you can't tell from the code and git whether it still holds
        5. What is never yours to drop:
           - the person's preferences and corrections (`feedback_*`, "don't…", "always…"): shorten at most
           - anything with a reason you can't check (a decision, a constraint from outside the repository)
           - secrets policy, safety rules, release steps
           Those go to ask if they look stale.
        6. Write. Before your first change, copy each file you'll change, keeping its folder, under {backup}: the
           person compares against it. One index line per memory, under ~150 characters, the hook only (the detail
           lives in the file). Dates absolute. Commit hashes, canvas ids and "built in …" lists leave the index: git
           and the memory file have them. Aim for each file at 60 % of its limit at most, so it doesn't overflow
           again next week (MEMORY.md: 120 lines and 15 000 bytes; CLAUDE.md and AGENTS.md: 120 lines). A memory
           file over ~20 KB is read whole whenever it's opened: cut it to what still holds, the rest to archive.
           Other sessions write these files while you work: read a file again right before you change it, change
           lines, never write the whole file back from an old copy. Touch nothing but the files named above.

        ## The report (your last message)

        ```
        <file>  <before> → <after>  (<limit>)
          archived  N  — one line each: what, why (path gone / finished 2026-10-30 / overruled by X)
          merged    N  — what into what
          moved     N  — what, where
          shortened N
          asks      N
        ```

        Then the questions, numbered, each answered with keep / drop / a word. Having changed nothing yet, end
        with: "Say apply to make these changes."
        """#
}
