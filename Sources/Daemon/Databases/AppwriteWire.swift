import Core
import Foundation

/// Appwrite (1.8, TablesDB) over its REST API: a project's database, its tables and rows. The endpoint is the
/// database's host ("https://appwrite.example.com", /v1 or not), the project's ID its user, an API key its password.
/// Appwrite has no SQL: the statements Kelp's tab and agents write are read in a narrow form and said as its queries —
/// SELECT * | count(*) | columns FROM t [WHERE …] [ORDER BY …] [LIMIT n] [OFFSET n]; INSERT INTO t (…) VALUES (…), …;
/// UPDATE t SET … WHERE …; DELETE FROM t WHERE …. A WHERE has =, <>, <, <=, >, >=, [NOT] LIKE ('%a%', 'a%', '%a'),
/// IS [NOT] NULL, [NOT] IN (…), [NOT] BETWEEN, AND, OR and brackets. The user's edits go in one Appwrite transaction.
struct AppwriteWire: DatabaseRunner {
    let c: DatabaseConnection
    /// Its change can't be tried and taken back, so its count is only what the rows matched when asked.
    var holdsAllowed: Bool { false }

    struct Endpoint {
        var base: String, project: String, key: String, database: String
    }

    static func endpoint(_ c: DatabaseConnection) throws -> Endpoint {
        let db = c.database
        var host = (db.host ?? "").trimmingCharacters(in: .whitespaces)
        var scheme = db.ssl == "disable" ? "http" : "https"
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) {
            scheme = String(prefix.dropLast(3))
            host.removeFirst(prefix.count)
        }
        while host.hasSuffix("/") { host.removeLast() }
        if host.hasSuffix("/v1") { host.removeLast(3) }
        guard !host.isEmpty else { throw DatabaseFailure.failed("\(db.name) has no endpoint (https://…/v1).") }
        guard let project = db.user, !project.isEmpty else {
            throw DatabaseFailure.failed("\(db.name) needs its Project ID: the project's Settings in Appwrite.")
        }
        guard let key = c.password, !key.isEmpty else {
            throw DatabaseFailure.failed(
                "Kelp has no password for \(db.name), its API key: Edit… to paste one (the project's Overview › "
                    + "API keys, with databases.read, tables.read, rows.read and rows.write).")
        }
        return Endpoint(
            base: "\(scheme)://\(host)\(db.port.map { ":\($0)" } ?? "")/v1", project: project, key: key,
            database: db.database ?? "")
    }

    // MARK: What the server says

    /// "Appwrite 1.8.1": asked without the key.
    func version() async throws -> String? {
        let answer = try await Self.call(try Self.endpoint(c), "GET", "/health/version", signed: false)
        return "Appwrite " + (answer["version"] as? String ?? "")
    }

    /// The project's databases, by ID.
    func databases() async throws -> [String] {
        let answer = try await Self.call(
            try Self.endpoint(c), "GET", "/tablesdb", queries: [["method": "limit", "values": [100]]])
        return (answer["databases"] as? [[String: Any]] ?? []).compactMap { $0["$id"] as? String }
    }

    func schema() async throws -> DatabaseSchema {
        let server = try await Self.withDatabase(try Self.endpoint(c))
        var tables: [DatabaseSchema.Table] = []
        while true {
            let answer = try await Self.call(
                server, "GET", "/tablesdb/\(Self.path(server.database))/tables",
                queries: [["method": "limit", "values": [100]], ["method": "offset", "values": [tables.count]]])
            let page = answer["tables"] as? [[String: Any]] ?? []
            tables += page.map(Self.table)
            if page.isEmpty || tables.count >= answer["total"] as? Int ?? 0 { break }
        }
        return DatabaseSchema(tables: tables)
    }

    /// One table as Kelp shows it: $id first (its key), its columns, then when it was made and changed.
    static func table(_ t: [String: Any]) -> DatabaseSchema.Table {
        let id = t["$id"] as? String ?? "", name = t["name"] as? String
        let columns = (t["columns"] as? [[String: Any]] ?? []).compactMap { c -> DatabaseSchema.Column? in
            guard let key = c["key"] as? String else { return nil }
            let type = (c["type"] as? String ?? "string") + (c["array"] as? Bool == true ? "[]" : "")
            return .init(name: key, type: type, nullable: c["required"] as? Bool != true, primary: false)
        }
        let indexes = (t["indexes"] as? [[String: Any]] ?? []).map { index in
            let columns = (index["columns"] ?? index["attributes"]) as? [String] ?? []   // TablesDB says columns
            return "\(index["key"] as? String ?? "") (\(columns.joined(separator: ", ")))"
        }
        return .init(
            name: id,
            columns: [.init(name: "$id", type: "string", nullable: false, primary: true)] + columns + [
                .init(name: "$createdAt", type: "datetime", nullable: false, primary: false),
                .init(name: "$updatedAt", type: "datetime", nullable: false, primary: false)
            ], indexes: indexes, comment: name == id ? nil : name)
    }

    // MARK: Statements

    func read(_ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        if sql == "SELECT 1" {   // the panel's "is it there?": the key and the project answer
            _ = try await Self.call(
                try Self.endpoint(c), "GET", "/tablesdb", queries: [["method": "limit", "values": [1]]])
            return DatabaseRows(columns: ["?column?"], rows: [["1"]], total: 1)
        }
        guard case .select(let select) = try AppwriteSQL.parse(sql) else { throw DatabaseFailure.change }
        let server = try await Self.withDatabase(try Self.endpoint(c))
        let kinds = try await Self.kinds(server, select.table)
        var queries = select.condition.map { kinds.queries($0) } ?? []
        if select.count {
            let answer = try await Self.call(
                server, "GET", Self.rows(server, select.table), queries: queries + [["method": "limit", "values": [1]]])
            return DatabaseRows(columns: ["count"], rows: [[String(answer["total"] as? Int ?? 0)]], total: 1)
        }
        if let names = select.columns { queries.append(["method": "select", "values": names]) }
        for (column, ascending) in select.orders {
            queries.append(["method": ascending ? "orderAsc" : "orderDesc", "attribute": column])
        }
        queries.append(["method": "limit", "values": [min(select.limit ?? DatabaseEngines.keep, DatabaseEngines.keep)]])
        if let offset = select.offset { queries.append(["method": "offset", "values": [offset]]) }
        let answer = try await Self.call(server, "GET", Self.rows(server, select.table), queries: queries)
        let found = answer["rows"] as? [[String: Any]] ?? []
        let columns = select.columns ?? kinds.columns
        let total =
            select.limit == nil ? min(answer["total"] as? Int ?? found.count, DatabaseEngines.countLimit) : found.count
        return DatabaseRows(
            columns: columns, rows: found.map { row in columns.map { Self.text(row[$0]) } },
            total: max(total, found.count))
    }

    /// Not run: what it would touch (Appwrite can't run a change and take it back to show it).
    func trial(_ sql: String) async throws -> DatabaseRows {
        let statement = try AppwriteSQL.parse(sql)
        let server = try await Self.withDatabase(try Self.endpoint(c))
        switch statement {
        case .select: throw DatabaseFailure.failed("It doesn't change anything.")
        case .insert(let insert): return DatabaseRows(changed: insert.rows.count)
        case .update(let table, _, let condition), .delete(let table, let condition):
            let kinds = try await Self.kinds(server, table)
            return DatabaseRows(changed: try await Self.ids(server, table, condition, kinds).count)
        }
    }

    func write(_ sql: String, allowed: Int?) async throws -> DatabaseRows {
        let changed = try await apply([sql])
        return DatabaseRows(changed: changed)
    }

    /// All of them in one Appwrite transaction: committed together, or rolled back.
    func apply(_ statements: [String]) async throws -> Int {
        let parsed = try statements.map(AppwriteSQL.parse)
        let server = try await Self.withDatabase(try Self.endpoint(c))
        let started = try await Self.call(server, "POST", "/tablesdb/transactions", body: ["ttl": 300])
        guard let tx = started["$id"] as? String else {
            throw DatabaseFailure.failed("Appwrite didn't start a transaction.")
        }
        do {
            var changed = 0
            for statement in parsed { changed += try await Self.run(server, statement, tx) }
            _ = try await Self.call(server, "PATCH", "/tablesdb/transactions/\(Self.path(tx))", body: ["commit": true])
            return changed
        } catch {
            // Not rolled back now: it lapses at its ttl, uncommitted. The error said is the statement's.
            do {
                _ = try await Self.call(
                    server, "PATCH", "/tablesdb/transactions/\(Self.path(tx))", body: ["rollback": true])
            } catch {}
            throw error
        }
    }

    private static func run(_ e: Endpoint, _ statement: AppwriteSQL.Statement, _ tx: String) async throws -> Int {
        switch statement {
        case .select: throw DatabaseFailure.failed("A SELECT changes nothing: run it as a read.")
        case .insert(let insert):
            let kinds = try await kinds(e, insert.table)
            for row in insert.rows {
                var data: [String: Any] = [:], id = "unique()"
                for (column, value) in zip(insert.columns, row) {
                    if column == "$id", case .text(let given) = value {
                        id = given
                    } else {
                        data[column] = kinds.value(value, column)
                    }
                }
                _ = try await call(
                    e, "POST", rows(e, insert.table), body: ["rowId": id, "data": data, "transactionId": tx])
            }
            return insert.rows.count
        case .update(let table, let set, let condition):
            let kinds = try await kinds(e, table)
            var data: [String: Any] = [:]
            for (column, value) in set { data[column] = kinds.value(value, column) }
            let found = try await ids(e, table, condition, kinds)
            for id in found {
                _ = try await call(
                    e, "PATCH", rows(e, table) + "/" + path(id), body: ["data": data, "transactionId": tx])
            }
            return found.count
        case .delete(let table, let condition):
            let found = try await ids(e, table, condition, try await kinds(e, table))
            for id in found {
                _ = try await call(e, "DELETE", rows(e, table) + "/" + path(id), body: ["transactionId": tx])
            }
            return found.count
        }
    }

    /// The rows a WHERE names: "$id" = '…' as it is (the tab's edits), else asked for (5 000 at most).
    private static func ids(_ e: Endpoint, _ table: String, _ condition: AppwriteSQL.Condition, _ kinds: Kinds)
        async throws -> [String]
    {
        if case .test("equal", "$id", let values) = condition {
            return values.compactMap { if case .text(let id) = $0 { id } else { nil } }
        }
        let limit = 5000
        let answer = try await call(
            e, "GET", rows(e, table),
            queries: kinds.queries(condition) + [
                ["method": "select", "values": ["$id"]], ["method": "limit", "values": [limit]]
            ])
        guard answer["total"] as? Int ?? 0 <= limit else {
            throw DatabaseFailure.failed(
                "That's more than \(limit) rows: Kelp changes Appwrite's rows \(limit) at a time.")
        }
        return (answer["rows"] as? [[String: Any]] ?? []).compactMap { $0["$id"] as? String }
    }

    // MARK: Columns and values

    /// A table's columns in order, with each one's type: values are sent as Appwrite wants them (2025, not '2025').
    struct Kinds {
        var columns: [String]
        var types: [String: (type: String, array: Bool)]

        func value(_ value: AppwriteSQL.Value, _ column: String) -> Any {
            let kind = types[column]
            switch value {
            case .null: return NSNull()
            case .bool(let flag): return flag
            case .text(let given), .number(let given): return Kinds.coerce(given, kind)
            }
        }

        static func coerce(_ s: String, _ kind: (type: String, array: Bool)?) -> Any {
            let structured = kind?.array == true || ["point", "line", "polygon", "relationship"].contains(kind?.type)
            if structured, s.first == "[" || s.first == "{" {
                do { return try JSONSerialization.jsonObject(with: Data(s.utf8)) } catch {}   // not JSON: as text
            }
            switch kind?.type {
            case "integer": return Int(s) ?? s
            case "double": return Double(s) ?? s
            case "boolean":
                if ["true", "t", "1", "yes"].contains(s.lowercased()) { return true }
                if ["false", "f", "0", "no"].contains(s.lowercased()) { return false }
                return s
            default: return s
            }
        }

        /// Top-level ANDs as separate queries, as Appwrite ANDs them.
        func queries(_ c: AppwriteSQL.Condition) -> [[String: Any]] {
            if case .all(let parts) = c { return parts.map(query) }
            return [query(c)]
        }

        func query(_ c: AppwriteSQL.Condition) -> [String: Any] {
            switch c {
            case .all(let parts): return ["method": "and", "values": parts.map(query)]
            case .any(let parts): return ["method": "or", "values": parts.map(query)]
            case .test(let method, let column, let values):
                var query: [String: Any] = ["method": method, "attribute": column]
                if !values.isEmpty { query["values"] = values.map { value($0, column) } }
                return query
            }
        }
    }

    private static func kinds(_ e: Endpoint, _ table: String) async throws -> Kinds {
        let found = self.table(try await call(e, "GET", "/tablesdb/\(path(e.database))/tables/\(path(table))"))
        var types: [String: (type: String, array: Bool)] = ["$sequence": ("integer", false)]
        for c in found.columns {
            let array = c.type.hasSuffix("[]")
            types[c.name] = (array ? String(c.type.dropLast(2)) : c.type, array)
        }
        return Kinds(columns: found.columns.map(\.name), types: types)
    }

    /// A value as text: numbers as written, true/false, a list or an object as JSON.
    static func text(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull: return nil
        case let text as String: return text
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID()
                ? (number.boolValue ? "true" : "false") : number.stringValue
        case let other?:
            guard JSONSerialization.isValidJSONObject(other) else { return "\(other)" }
            do {
                let data = try JSONSerialization.data(withJSONObject: other, options: [.withoutEscapingSlashes])
                return String(decoding: data, as: UTF8.self)
            } catch { return "\(other)" }
        }
    }

    // MARK: HTTP

    /// A database ID left out: the project's only one.
    private static func withDatabase(_ e: Endpoint) async throws -> Endpoint {
        guard e.database.isEmpty else { return e }
        let answer = try await call(e, "GET", "/tablesdb", queries: [["method": "limit", "values": [2]]])
        let ids = (answer["databases"] as? [[String: Any]] ?? []).compactMap { $0["$id"] as? String }
        guard ids.count == 1 else {
            throw DatabaseFailure.failed(
                ids.isEmpty ? "The project has no database." : "Pick one of the project's databases: Edit… › Database.")
        }
        var one = e
        one.database = ids[0]
        return one
    }

    private static func rows(_ e: Endpoint, _ table: String) -> String {
        "/tablesdb/\(path(e.database))/tables/\(path(table))/rows"
    }

    private static func path(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    static func call(
        _ e: Endpoint, _ method: String, _ path: String, queries: [[String: Any]] = [], body: [String: Any]? = nil,
        signed: Bool = true
    ) async throws -> [String: Any] {
        var parts = URLComponents(string: e.base + path)
        if !queries.isEmpty {
            parts?.queryItems = try queries.map { query in
                let data = try JSONSerialization.data(withJSONObject: query, options: [.withoutEscapingSlashes])
                return URLQueryItem(name: "queries[]", value: String(decoding: data, as: UTF8.self))
            }
            // PHP reads "+" in a query as a space
            let encoded = parts?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            parts?.percentEncodedQuery = encoded
        }
        guard let url = parts?.url else { throw DatabaseFailure.failed("Not an address: \(e.base + path)") }
        var request = URLRequest(url: url, timeoutInterval: DatabaseEngines.readTimeout)
        request.httpMethod = method
        if signed {   // a wrong project fails even what needs none
            request.setValue(e.project, forHTTPHeaderField: "X-Appwrite-Project")
            request.setValue(e.key, forHTTPHeaderField: "X-Appwrite-Key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch let error as URLError {
            throw failure(error, e)
        }
        var object: [String: Any] = [:]
        if !data.isEmpty {   // a proxy's HTML page instead of JSON: said by its status below
            do { object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] } catch {}
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else {
            throw DatabaseFailure.failed(object["message"] as? String ?? "Appwrite answered \(status).")
        }
        return object
    }

    private static func failure(_ error: URLError, _ e: Endpoint) -> DatabaseFailure {
        let host = URL(string: e.base)?.host ?? e.base
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .failed("Can't find \(host) on the network: is a VPN or SSH needed to reach it?")
        case .timedOut: return .failed("\(host) didn't answer in \(Int(DatabaseEngines.readTimeout)) s.")
        case .cannotConnectToHost: return .failed("Can't connect: Connection refused")
        default: return .failed(error.localizedDescription)
        }
    }
}
