import Foundation
import GRDB
import Core

// The daemon's records as SQLite rows (Store). Core's models know nothing of the database: the app and the CLI don't
// link GRDB.
extension Repo: FetchableRecord, PersistableRecord { public static let databaseTableName = "repo" }
extension Worktree: FetchableRecord, PersistableRecord { public static let databaseTableName = "worktree" }
extension Session: FetchableRecord, PersistableRecord { public static let databaseTableName = "session" }
extension DiffComment: FetchableRecord, PersistableRecord { public static let databaseTableName = "diffComment" }
extension Routine: FetchableRecord, PersistableRecord { public static let databaseTableName = "routine" }
extension Routine.Run: FetchableRecord, PersistableRecord { public static let databaseTableName = "routineRun" }
