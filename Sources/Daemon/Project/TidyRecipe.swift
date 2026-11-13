extension Recipes {
    /// Tidy Up (Skills & MCP › Needs a Look): `{instructionFiles}` the files to tidy, `{before}` the copies Kelp
    /// made of them (`addons.tidy`). The agent changes the files at once and the person reviews afterwards. The test
    /// every line has to pass is Anthropic's: could an agent find it in the repo, and would it look? Tried on Kelp's
    /// own memory and AGENTS.md: a brief that asked first and kept anything with a reason left AGENTS.md at 95 %.
    static let tidyInstructions = #"""
        Tidy up the files agents read before every chat in this project: {instructionFiles}.
        Every line in them is read on every request and takes attention from the lines that matter. Make them as short
        as they can be while an agent still makes no mistake it wouldn't make with the long version. Kelp has copied the
        files to {before} before you start, so change them now: ask nothing before you finish.

        ## The test every line has to pass

        1. Could an agent find this by reading the code, git or the docs in the repository?
        2. Would it actually go and look before it needs it?
        If both are yes, the line goes. If the agent couldn't find it, or wouldn't look in time, it stays, as short as
        it can be said.

        What stays: the commands that check work (build, test, lint, how to run one test) · places where the code
        misleads (a pattern everywhere that new code must not copy, a folder that looks unused but isn't) · decisions
        not in the repo, with their reason in a few words · corrections the person gave (feedback memories) · rules that
        differ from what the tools do by default.

        What goes, even when true: descriptions of the architecture, modules or folder layout · dependency lists ·
        file-by-file descriptions · history (what was built when, commit hashes, canvas and page ids, "built in …",
        "local", version numbers) · lists of hand checks and traps of work that has shipped · debugging fixes · anything
        another of these files or the code's own comments already say · anything a test or a hook enforces (the test is
        the rule now).

        When you cut a description, a table or a tour, lift out any rule hidden in it ("never", "only", "always",
        "must", "don't") that no test enforces, as a line of its own.

        ## Claude Code's memory

        - MEMORY.md is an index: one line per memory, under ~100 characters, a hook only. No ids, hashes or dates in it.
        - A memory about finished work keeps only what still steers future work (a decision and why, a trap the code
          doesn't show). If nothing is left, move the file to `archive/` beside MEMORY.md and drop its index line. Two
          memories about one thing become one: the other file goes to `archive/`.
        - A feedback memory (the person's preference or correction) is kept, shortened. Never archive one.
        - A memory that tells another way to do what CLAUDE.md or AGENTS.md says: the checked-in file wins and the
          memory goes. A feedback memory instead gets "contradicts CLAUDE.md — check" and is listed in your report.
        - Check before you trust: a path the memory names (`test -e`), a symbol (`git grep -qw`), a commit (`git
          cat-file -e <hash>^{commit}`). Claude Code's past chats (JSONL files in the folder above its memory folder)
          can be grepped for one narrow term, never read whole.

        ## How much

        Expect to remove at least half of each file. If you keep more than 70 % of one, say in the report which sections
        you kept and why each passes the test. A memory file over ~5 KB is cut to what passes the test.

        Other sessions write these files while you work: read a file again right before you change it, change it in
        place, never write it back from an old copy. Touch nothing but the files named above.

        ## The report (your last message)

        ```
        <file>  <lines before> → <after> lines, <bytes before> → <after> bytes
          cut: what kinds of lines went, one line each, with how many
          kept: the sections that stayed, one line each
        ```
        Then, numbered, only the few things you weren't sure enough to cut and left as they were, each answered with one
        word ("cut" / "keep"). End with these two lines:
        Compare with Before Tidy Up (the file's menu in Skills & MCP) shows every change.
        Say undo and I'll put back every file from the copies.

        If the person says undo: copy every file back from {before} over the one it was copied from (a memory folder
        whole, so files you moved to archive/ go too), and say when it's done.
        """#
}
