import Core
import Foundation
import GRDB

// The database's schema: every migration, in the order they ran, never edited once shipped.

extension Store {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "repo") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("path", .text).notNull().unique()
                table.column("baseBranch", .text).notNull()
                table.column("copyFiles", .jsonText).notNull()
            }
            try db.create(table: "worktree") { table in
                table.primaryKey("id", .text)
                table.column("repoId", .text).notNull().references("repo", onDelete: .cascade)
                table.column("branch", .text).notNull()
                table.column("path", .text).notNull()
                table.column("note", .text).notNull()
                table.column("archived", .boolean).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "session") { table in
                table.primaryKey("id", .text)
                table.column("worktreeId", .text)
                table.column("cwd", .text).notNull()
                table.column("command", .text).notNull()
                table.column("agent", .text)
                table.column("status", .text).notNull()
                table.column("unread", .boolean).notNull()
                table.column("pid", .integer).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "diffComment") { table in
                table.primaryKey("id", .text)
                table.column("worktreeId", .text).notNull()
                table.column("file", .text).notNull()
                table.column("startLine", .integer).notNull()
                table.column("endLine", .integer).notNull()
                table.column("quote", .text).notNull()
                table.column("text", .text).notNull()
                table.column("state", .text).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "session") { table in
                table.add(column: "title", .text).notNull().defaults(to: "")
                table.add(column: "titleManual", .boolean).notNull().defaults(to: false)
                table.add(column: "summary", .text).notNull().defaults(to: "")
                table.add(column: "argv", .jsonText).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "worktree") { table in
                table.add(column: "issue", .text).notNull().defaults(to: "")
                table.add(column: "issueURL", .text).notNull().defaults(to: "")
                table.add(column: "linearIssueId", .text).notNull().defaults(to: "")
                table.add(column: "prNumber", .integer)
                table.add(column: "prURL", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "worktree") { t in t.add(column: "base", .text).notNull().defaults(to: "") }
        }
        migrator.registerMigration("v5") { db in
            try db.alter(table: "session") { t in t.add(column: "statusAt", .datetime) }
        }
        migrator.registerMigration("v6") { db in
            try db.create(table: "uiState") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
            // A workspace's layout goes with it, however it's removed (its project's removal cascades here too).
            try db.execute(
                sql:
                    "CREATE TRIGGER uiStateLayout AFTER DELETE ON worktree BEGIN DELETE FROM uiState WHERE key = 'layout/' || OLD.id; END"
            )
        }
        migrator.registerMigration("v7") { db in
            try db.alter(table: "session") { t in t.add(column: "workDir", .text) }
        }
        migrator.registerMigration("v8") { db in
            try db.alter(table: "session") { t in t.add(column: "progress", .integer) }
        }
        migrator.registerMigration("v9") { db in
            try db.alter(table: "session") { t in t.add(column: "exitCode", .integer) }
        }
        migrator.registerMigration("v10") { db in
            try db.alter(table: "session") { t in t.add(column: "profile", .text) }
        }
        migrator.registerMigration("v11") { db in   // a workspace's review comments go with it (its project's removal included)
            try db.execute(sql: "DELETE FROM diffComment WHERE worktreeId NOT IN (SELECT id FROM worktree)")
            try db.execute(
                sql: """
                    CREATE TRIGGER worktreeComments AFTER DELETE ON worktree
                    BEGIN DELETE FROM diffComment WHERE worktreeId = OLD.id; END
                    """)
        }
        migrator.registerMigration("v12") { db in
            try db.alter(table: "session") { t in t.add(column: "tmux", .text) }
        }
        migrator.registerMigration("v13") { db in
            for table in ["repo", "worktree", "session"] {
                try db.alter(table: table) { t in t.add(column: "revision", .integer) }
            }
        }
        migrator.registerMigration("v14") { db in
            try db.alter(table: "session") { table in
                table.add(column: "goal", .text)
                table.add(column: "background", .text)
            }
        }
        migrator.registerMigration("v15") { db in
            try db.alter(table: "session") { t in t.add(column: "running", .text) }
        }
        migrator.registerMigration("v16") { db in
            try db.alter(table: "session") { t in t.add(column: "awaiting", .text) }
        }
        migrator.registerMigration("v17") { db in   // routines go with their project, runs with their routine
            try db.create(table: "routine") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("repoId", .text).notNull().references("repo", onDelete: .cascade)
                table.column("agent", .text).notNull()
                table.column("model", .text)
                table.column("prompt", .text).notNull()
                table.column("every", .text).notNull()
                table.column("time", .integer).notNull()
                table.column("weekday", .integer).notNull()
                table.column("enabled", .boolean).notNull()
                table.column("onWake", .boolean).notNull()
                table.column("worktreeId", .text)
                table.column("checked", .datetime).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "routineRun") { table in
                table.primaryKey("id", .text)
                table.column("routineId", .text).notNull().indexed().references("routine", onDelete: .cascade)
                table.column("sessionId", .text)
                table.column("due", .datetime).notNull()
                table.column("started", .datetime).notNull()
                table.column("ended", .datetime)
                table.column("outcome", .text).notNull()
                table.column("summary", .text).notNull()
            }
        }
        migrator.registerMigration("v18") { db in
            try db.alter(table: "session") { table in
                table.add(column: "limitHit", .text)
                table.add(column: "continueAt", .datetime)
            }
        }
        migrator.registerMigration("v19") { db in try db.alter(table: "session") { t in t.add(column: "parent", .text) }
        }
        migrator.registerMigration("v20") { db in
            try db.alter(table: "session") { t in t.add(column: "subagents", .text) }
        }
        migrator.registerMigration("v21") { db in
            try db.alter(table: "session") { t in t.add(column: "subagentTasks", .text) }
        }
        migrator.registerMigration("v22") { db in
            try db.create(table: "owedInput") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("session", .text).notNull().indexed().references("session", onDelete: .cascade)
                table.column("text", .text).notNull()
                table.column("draft", .boolean).notNull()
                table.column("paste", .boolean).notNull()
                table.column("report", .boolean).notNull()
            }
        }
        migrator.registerMigration("v23") { db in
            try db.alter(table: "session") { t in t.add(column: "subagentRuns", .text) }
        }
        migrator.registerMigration("session.startedBy") { db in
            try db.alter(table: "session") { t in t.add(column: "startedBy", .text) }
        }
        migrator.registerMigration("session.browser") { db in
            try db.alter(table: "session") { t in t.add(column: "browser", .text) }
        }
        migrator.registerMigration("session.quiet") { db in
            try db.alter(table: "session") { table in
                table.add(column: "quietSince", .datetime)
                table.add(column: "guessed", .boolean)
            }
        }
        migrator.registerMigration("session.choices") { db in
            try db.alter(table: "session") { t in t.add(column: "choices", .text) }
        }
        migrator.registerMigration("uiState.viewed") { db in   // a workspace's read marks go with it, as its layout does
            try db.execute(
                sql:
                    "CREATE TRIGGER uiStateViewed AFTER DELETE ON worktree BEGIN DELETE FROM uiState WHERE key = 'viewed/' || OLD.id; END"
            )
        }
        migrator.registerMigration("diffComment.side") { db in
            try db.alter(table: "diffComment") { table in
                table.add(column: "side", .text)
                table.add(column: "commit", .text)
            }
        }
        // an agent's turns, kept for the diff of any of them; they go with their session
        migrator.registerMigration("turn") { db in
            try db.create(table: "turn") { table in
                table.primaryKey("id", .text)
                table.column("session", .text).notNull().indexed()
                table.column("tree", .text).notNull()
                table.column("head", .text)
                table.column("folder", .text).notNull()
                table.column("prompt", .text).notNull()
                table.column("at", .datetime).notNull()
            }
            try db.execute(
                sql:
                    "CREATE TRIGGER sessionTurns AFTER DELETE ON session BEGIN DELETE FROM turn WHERE session = OLD.id; END"
            )
        }
        migrator.registerMigration("diffComment.author") { db in
            try db.alter(table: "diffComment") { t in t.add(column: "author", .text) }
        }
        migrator.registerMigration("diffComment.onCommit") { db in
            try db.alter(table: "diffComment") { t in t.add(column: "onCommit", .text) }
        }
        migrator.registerMigration("session.origin") { db in
            try db.alter(table: "session") { t in t.add(column: "origin", .text) }
        }
        migrator.registerMigration("worktree.madeBy") { db in
            try db.alter(table: "worktree") { t in t.add(column: "madeBy", .text) }
        }
        // a project's databases: added by hand, or what was changed of a found one
        migrator.registerMigration("database") { db in
            try db.create(table: "database") { table in
                table.primaryKey("id", .text)   // repoId/name
                table.column("repoId", .text).notNull().indexed().references("repo", onDelete: .cascade)
                table.column("byHand", .boolean).notNull()
                table.column("json", .text).notNull()   // the Database, as sent
            }
        }
        migrator.registerMigration("databaseLibrary") { db in   // "All my projects": no project's
            try db.create(table: "databaseLibrary") { table in
                table.primaryKey("id", .text)   // its name
                table.column("json", .text).notNull()
            }
        }
        // Production is the user's word only: the marks Kelp guessed from a host or a name go, once. Kelp didn't keep
        // who set a mark, so all go; a server elsewhere stays read only for agents through its access.
        migrator.registerMigration("database.productionByHand") { db in
            for table in ["database", "databaseLibrary"] {
                for row in try Row.fetchAll(db, sql: "SELECT id, json FROM \(table)") {
                    let id: String = row["id"], json: String = row["json"]
                    guard
                        var info = Log.store.attempt(
                            "reading the saved database \(id)",
                            {
                                try JSONDecoder().decode(DatabaseInfo.self, from: Data(json.utf8))
                            }),
                        info.production
                    else { continue }
                    info.production = false
                    if info.environment == .production { info.environment = nil }
                    if DatabaseFind.isRemote(info), info.access == .ask || info.access == .free { info.access = .read }
                    let out = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
                    try db.execute(sql: "UPDATE \(table) SET json = ? WHERE id = ?", arguments: [out, id])
                }
            }
        }
        // What the daemon decides by or keeps for itself, out of the app's state, which `state.set` writes as it's
        // told: the user's trust as it was, and the port forwardings (there a JSON string of their JSON) as their JSON.
        // Copied, not moved: an older daemon on this store (a downgrade) still finds them where it looks; from here on
        // daemonState is what counts.
        migrator.registerMigration("daemonState") { db in
            try db.create(table: "daemonState") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
            try db.execute(
                sql: """
                    INSERT INTO daemonState (key, value)
                    SELECT key, value FROM uiState WHERE key IN ('lsp.trusted', 'extensions.trusted')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO daemonState (key, value)
                    SELECT key, json_extract(value, '$') FROM uiState
                    WHERE key = 'ports.forwards' AND json_valid(value) AND json_type(value) = 'text'
                    """)
        }
        return migrator
    }
}
