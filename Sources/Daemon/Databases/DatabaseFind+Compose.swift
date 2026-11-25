import Core
import Foundation

// Databases in compose files: postgres and mysql services, their ports, users and passwords, with .env interpolation.

extension DatabaseFind {
    /// Reads `KEY=value` lines the way .env files have them (with export, quotes and comments). When a key appears
    /// more than once, the last value is kept.
    static func variables(_ text: String) -> [String: String] {
        Dictionary(pairs(text), uniquingKeysWith: { $1 })
    }

    /// Reads the same lines as `variables`, as pairs in their order.
    static func pairs(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { return nil }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (line[..<eq].trimmingCharacters(in: .whitespaces), unquoted(String(line[line.index(after: eq)...])))
        }
    }

    /// Fills in `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:+other}`, `$VAR` and `$$` from `env`, as compose
    /// does. Returns nil when a `${VAR:?message}` (or `${VAR?message}`) isn't set, because compose wouldn't start.
    static func interpolated(_ value: String, _ env: [String: String]) -> String? {
        var missing = false
        let filled = value.replacing(
            /\$\$|\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?+])([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)/
        ) { match -> String in
            guard let name = match.output.1 ?? match.output.4 else { return "$" }
            let set = env[String(name)], op = match.output.2 ?? "", word = String(match.output.3 ?? "")
            let given = op.hasPrefix(":") ? set.flatMap { $0.isEmpty ? nil : $0 } : set
            switch op.last {
            case "-": return given ?? word
            case "?":
                missing = missing || given == nil
                return given ?? ""
            case "+": return given == nil ? "" : word
            default: return set ?? ""
            }
        }
        return missing ? nil : filled
    }

    /// Finds the services of a postgres or mysql image, with their published port and the user, password and
    /// database from their `environment` and `env_file`. `file` reads a file by its path in the project.
    static func compose(
        _ text: String, source: String, env vars: [String: String] = [:], file: (String) -> String? = { _ in nil }
    ) -> [FoundDatabase] {
        var found: [FoundDatabase] = []
        let folder = (source as NSString).deletingLastPathComponent
        for service in services(text) {
            guard let engine = service.values["image"].flatMap(DatabaseInfo.Engine.init(image:)) else { continue }
            guard let inner = engine.defaultPort else { continue }
            // The container's environment: its env_file first, then `environment`, which wins.
            let given = service.envFiles.compactMap { inProject(folder, $0).flatMap(file) }.map(variables)
                .reduce(into: [:]) { $0.merge($1) { $1 } }.merging(service.env) { $1 }
            let env = given.compactMapValues { interpolated($0, vars) }
            let port = service.ports.compactMap { interpolated($0, vars).flatMap { published($0, inner: inner) } }.first
            var user: String?, password: String?, database: String?
            if engine == .postgres {
                user = env["POSTGRES_USER"] ?? "postgres"
                password = env["POSTGRES_PASSWORD"]
                database = env["POSTGRES_DB"] ?? user
            } else {
                user = env["MYSQL_USER"] ?? env["MARIADB_USER"] ?? "root"
                password =
                    user == "root"
                    ? env["MYSQL_ROOT_PASSWORD"] ?? env["MARIADB_ROOT_PASSWORD"]
                    : env["MYSQL_PASSWORD"] ?? env["MARIADB_PASSWORD"]
                database = env["MYSQL_DATABASE"] ?? env["MARIADB_DATABASE"]
            }
            let db = DatabaseInfo(
                name: database ?? service.name, engine: engine, source: source, host: port == nil ? nil : "localhost",
                port: port, database: database, user: user)
            found.append(FoundDatabase(database: db, password: password, service: (service.name, inner)))
        }
        return found
    }

    /// The path in the project of a file a compose file in `folder` names, or nil for one outside the project.
    static func inProject(_ folder: String, _ path: String) -> String? {
        let full = ((folder as NSString).appendingPathComponent(path) as NSString).standardizingPath
        return path.hasPrefix("/") || path.hasPrefix("~") || full.split(separator: "/").contains("..") ? nil : full
    }

    struct Service {
        var name: String
        var values: [String: String] = [:]
        var ports: [String] = [], envFiles: [String] = []
        var env: [String: String] = [:]
    }

    /// Reads the `services:` block line by line. A service sits at the first indent under the block, and the
    /// service's keys sit at the first indent under the service, however many spaces that is.
    static func services(_ text: String) -> [Service] {
        var services: [Service] = [], inServices = false, serviceIndent = -1, keyIndent = -1, section = ""
        for raw in expandingAnchors(text).split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inServices = trimmed == "services:"
                serviceIndent = -1
                continue
            }
            guard inServices else { continue }
            if serviceIndent < 0 { serviceIndent = indent }
            if indent == serviceIndent {
                services.append(Service(name: String(trimmed.dropLast(trimmed.hasSuffix(":") ? 1 : 0))))
                section = ""
                keyIndent = -1
                continue
            }
            guard indent > serviceIndent, !services.isEmpty else { continue }
            if keyIndent < 0 { keyIndent = indent }
            read(trimmed, key: indent == keyIndent, section: &section, into: &services[services.count - 1])
        }
        return services
    }

    /// Reads one line under a service: one of its keys, or a line in its `ports`, `environment` or `env_file`.
    private static func read(_ trimmed: String, key atKey: Bool, section: inout String, into service: inout Service) {
        if trimmed.hasPrefix("- ") {
            let item = unquoted(String(trimmed.dropFirst(2)))
            if section == "ports" { service.ports.append(item) }
            if section == "environment", let eq = item.firstIndex(of: "=") {
                service.env[String(item[..<eq])] = unquoted(String(item[item.index(after: eq)...]))
            }
            // `- path: db.env` is the long form of `- db.env`.
            if section == "env_file" { service.envFiles.append(unquoted(item.replacing(/^path:/, with: ""))) }
            return
        }
        guard let colon = trimmed.firstIndex(of: ":") else { return }
        let key = String(trimmed[..<colon]), value = unquoted(String(trimmed[trimmed.index(after: colon)...]))
        if atKey {
            section = value.isEmpty ? key : ""
            // A flow list on the key's own line, such as ports: ["5433:5432", "8080:80"], or a single env_file.
            if key == "ports" || key == "env_file" {
                let items =
                    value.hasPrefix("[")
                    ? value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                        .map { unquoted($0.trimmingCharacters(in: .whitespaces)) } : value.isEmpty ? [] : [value]
                if key == "ports" { service.ports += items } else { service.envFiles += items }
            } else if !value.isEmpty {
                service.values[key] = value
            }
        } else if section == "environment" {
            service.env[key] = value
        }
    }

    /// Returns the port on this Mac that a `ports:` entry publishes the container's port `inner` on. Entries look like
    /// "5433:5432", "127.0.0.1:5433:5432" or "5432" (which publishes no port on this Mac).
    static func published(_ entry: String, inner: Int) -> Int? {
        let parts = entry.split(separator: "/").first.map { $0.split(separator: ":").map(String.init) } ?? []
        guard let target = parts.last.flatMap(Int.init), target == inner else { return nil }
        return parts.count >= 2 ? Int(parts[parts.count - 2]) : nil
    }
}
