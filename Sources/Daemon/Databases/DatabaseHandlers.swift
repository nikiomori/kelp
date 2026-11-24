import Core
import Foundation

// The db.* RPCs, each answered by Databases.

extension DatabaseList: Handled {
    // An agent may use these three methods on the databases of its own workspaces: list them, read their tables, and
    // run a statement (read-only, or a change when the database's `agentAccess` allows it, see `Databases.query`).
    // It may not look at another project's databases.
    static let agents = AgentAccess.acts
    func handle(_ dbs: Databases) throws -> [DatabaseInfo] {
        let agent = dbs.agent(origin: Sessions.asker) != nil
        return try dbs.connections(worktreeId).map(\.database).filter { !agent || $0.agentAccess != .hidden }
    }
}

extension DatabaseSchemaRead: AsyncHandled {
    static let agents = AgentAccess.acts
    func handle(_ dbs: Databases) async throws -> DatabaseSchema {
        try await dbs.schema(worktreeId, database, table: table, agent: dbs.agent(origin: Sessions.asker) != nil)
    }
}

extension DatabaseQuery: AsyncHandled {
    static let agents = AgentAccess.acts
    func handle(_ dbs: Databases, conn: Int) async throws -> QueryResult {
        try await dbs.stoppable(cancelId) {
            try await dbs.query(self, origin: Sessions.asker, asker: dbs.clients.connection(conn)?.peerPID)
        }
    }
}

extension DatabaseSave: Handled {
    func handle(_ dbs: Databases) throws -> DatabaseInfo {
        if adding == true, try dbs.named(database.name, in: worktreeId, library: library ?? false) {
            throw RPCError.invalidParams(
                "There's a database named \(database.name.trimmingCharacters(in: .whitespaces)) already: "
                    + "give this one another name.")
        }
        let secret = try password ?? container.map { try dbs.containerPassword($0, database.engine) } ?? nil
        return try dbs.save(worktreeId, database, password: secret, library: library ?? false)
    }
}

extension DatabaseRemove: Handled {
    func handle(_ dbs: Databases) throws -> Done {
        try dbs.remove(worktreeId, name, library: library ?? false)
        return Done()
    }
}

extension DatabaseCopy: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> DatabaseInfo { try await dbs.copy(worktreeId, database) }
}

extension DatabaseCopyRemove: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> Done {
        try await dbs.dropCopy(worktreeId, database)
        return Done()
    }
}

extension DatabaseActivity: Handled {
    func handle(_ dbs: Databases) throws -> DatabasesEvent { try dbs.activity(worktreeId) }
}

extension DatabaseResultRead: Handled {
    func handle(_ dbs: Databases) throws -> QueryResult? { dbs.result(worktreeId, id) }
}

extension Methods {
    static let databaseMethods: [any Answered.Type] = [
        DatabaseList.self, DatabaseSchemaRead.self, DatabaseQuery.self, DatabaseSave.self, DatabaseRemove.self,
        DatabaseCopy.self, DatabaseCopyRemove.self, DatabaseActivity.self, DatabaseResultRead.self, DatabaseDiff.self,
        DatabaseCancel.self
    ]
}
