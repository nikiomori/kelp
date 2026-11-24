import Core
import KelpKit

extension Builtins {
    /// The `kelp db` skill, for agents. It is written whenever the built-in is on, and the daemon gives it only to
    /// chats in a project with a database (`SessionSetup.hasDatabases`).
    static let databasesSkill = SkillSpec(
        name: "kelp-db",
        description:
                "Use when you need to read or change this project's database (Postgres, MySQL, SQLite, DuckDB, "
                + "Appwrite) in Kelp, the "
                + "IDE this session runs in: its tables, rows, a query plan, a fix to data. kelp db query runs it "
                + "without its password; the user sees what you ran, and a change waits for their Allow. Not psql "
                + "with the .env's password.",
        setting: SettingKeys.skillDatabases,
        body: """
        # The project's databases in Kelp

        This session runs inside Kelp and the `kelp` CLI is on PATH. Kelp found this project's databases (compose, .env,
        config/database.yml, SQLite and DuckDB files) or the user added them. Use `kelp db`, not psql or mysql with a
        password from the project's files: Kelp holds the passwords, and the user sees each statement you run in its
        Databases panel.

        - `kelp db list` — the databases: name, engine, where it was found, and what agents may do there (read only;
          read, ask to change; read, change freely). One listed as this branch's copy is the branch's own, made for
          trying changes: `--db` left out means it, not the database it's a copy of.
        - `kelp db schema [table] [--db name]` — tables with their row counts; with a table, its columns (type, null,
          primary key, → what a foreign key points to) and indexes. Read it before you write a query. Its last line
          says which migrations aren't applied, when Kelp knows the project's tool (Rails, Prisma, Django, Alembic,
          Drizzle, Laravel).
        - `kelp db query "SELECT …" [--db name] [--limit 200]` — a statement. Rows come as a table, 200 unless you
          ask, 1000 at most (page with LIMIT and OFFSET past that); cells over 200 characters are cut; a read stops
          after 15 s. `--json` prints one JSON object a line (every value a string, NULL as null), the summary on
          stderr. `--db` can be left out when there's one.
        - `kelp db open [name]` — the database in a tab beside you, for the user.

        Reads run in a read-only transaction. A change (INSERT, UPDATE, DELETE, DDL) goes by the database:
        - ask: Kelp tries it, rolls it back, and asks the user ("Allow changing 1204 rows of orders in app_dev?");
          your command waits for the answer, up to ten minutes, so run it with your shell tool's longest timeout
          (Claude Code's Bash: `timeout: 600000`). Cut off before an answer, it doesn't run and the question goes
          with it: run it once more with that timeout. Denied, it fails: don't retry it, ask the user what they want
          instead.
        - read (and every production database): refused. Tell the user what you would run, or use a dev database.
        - free: it runs.

        A change that takes several statements goes in one call, separated by `;`: Kelp runs them in one transaction,
        all of them or none, and asks the user once (SQLite, and Postgres or MySQL at an address; leave out BEGIN
        and COMMIT). Calls share nothing: each is on a connection of its own. Appwrite takes
        Kelp's narrow SQL only (SELECT, INSERT, UPDATE and DELETE on one table, a change by a WHERE): its error says
        what's in it. Prefer a migration in the project's own tool for schema changes the code depends on; use
        `kelp db` to look, to try a query, and for data fixes the user asked for.

        """
    )
}
