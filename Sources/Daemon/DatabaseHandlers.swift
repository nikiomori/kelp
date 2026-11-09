import Core
import Foundation

// db.*: the RPCs, each answered by Databases.

extension DatabaseList: Handled {
    func handle(_ dbs: Databases) throws -> [DatabaseInfo] {
        let agent = dbs.agent(origin: Sessions.asker) != nil
        return try dbs.connections(worktreeId).map(\.database).filter { !agent || $0.agentAccess != .hidden }
    }
}

extension DatabaseSchemaRead: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> DatabaseSchema {
        try await dbs.schema(worktreeId, database, table: table, agent: dbs.agent(origin: Sessions.asker) != nil)
    }
}

extension DatabaseQuery: AsyncHandled {
    func handle(_ dbs: Databases, conn: Int) async throws -> QueryResult {
        try await dbs.query(self, origin: Sessions.asker, asker: dbs.sessions.callers.pid(conn))
    }
}

extension DatabaseSave: Handled {
    func handle(_ dbs: Databases) throws -> DatabaseInfo {
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

extension DatabaseActivity: Handled {
    func handle(_ dbs: Databases) throws -> DatabasesEvent { try dbs.activity(worktreeId) }
}

extension DatabaseResultRead: Handled {
    func handle(_ dbs: Databases) throws -> QueryResult? { dbs.result(worktreeId, id) }
}

extension Methods {
    static let databaseMethods: [any Handled.Type] = [
        DatabaseList.self, DatabaseSave.self, DatabaseRemove.self, DatabaseActivity.self, DatabaseResultRead.self,
        DatabaseUse.self
    ]
    /// What talks to a server: off the handlers' threads, over its own connection.
    static let databaseAsyncMethods: [any AsyncHandled.Type] = [
        DatabaseQuery.self, DatabaseSchemaRead.self, DatabaseCopy.self, DatabaseCheck.self, DatabaseContainers.self,
        DatabaseImportSources.self, DatabaseImportRead.self, DatabaseImport.self, DatabaseStatus.self,
        DatabaseStart.self, DatabaseApply.self
    ]
}
