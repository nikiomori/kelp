import Core
import Foundation

// Databases in compose files: postgres and mysql services, their ports, users and passwords, with .env interpolation.

extension DatabaseFind {
    /// Services of a postgres or mysql image: their published port, user, password and database from `environment`.
    /// `KEY=value` lines (export, quotes and comments as .env files have them), the last of a key kept.
    static func variables(_ text: String) -> [String: String] {
        Dictionary(pairs(text), uniquingKeysWith: { $1 })
    }

    /// The same lines in their order.
    static func pairs(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { return nil }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (line[..<eq].trimmingCharacters(in: .whitespaces), unquoted(String(line[line.index(after: eq)...])))
        }
    }

    /// `${VAR}`, `${VAR:-default}`, `${VAR-default}` and `$VAR` filled in as compose does, from `env`.
    static func interpolated(_ value: String, _ env: [String: String]) -> String {
        value.replacing(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)/) { match in
            let name = String(match.output.1 ?? match.output.3 ?? "")
            return env[name].flatMap { $0.isEmpty ? nil : $0 } ?? String(match.output.2 ?? "")
        }
    }

    static func compose(_ text: String, source: String, env vars: [String: String] = [:]) -> [FoundDatabase] {
        var found: [FoundDatabase] = []
        for service in services(text) {
            guard let engine = service.values["image"].flatMap(DatabaseInfo.Engine.init(image:)) else { continue }
            guard let inner = engine.defaultPort else { continue }
            let env = service.env.mapValues { interpolated($0, vars) }
            let port = service.ports.compactMap { published(interpolated($0, vars), inner: inner) }.first
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

    struct Service {
        var name: String
        var values: [String: String] = [:]
        var ports: [String] = []
        var env: [String: String] = [:]
    }

    /// The `services:` block, line by line: a service at the first indent under it, its keys under that.
    static func services(_ text: String) -> [Service] {
        var services: [Service] = [], inServices = false, serviceIndent = -1, section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
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
                continue
            }
            guard indent > serviceIndent, !services.isEmpty else { continue }
            let last = services.count - 1
            if trimmed.hasPrefix("- ") {
                let item = unquoted(String(trimmed.dropFirst(2)))
                if section == "ports" { services[last].ports.append(item) }
                if section == "environment", let eq = item.firstIndex(of: "=") {
                    services[last].env[String(item[..<eq])] = unquoted(String(item[item.index(after: eq)...]))
                }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]), value = unquoted(String(trimmed[trimmed.index(after: colon)...]))
            if indent == serviceIndent + 2 || section.isEmpty {
                section = value.isEmpty ? key : ""
                // A flow list on the key's own line: ports: ["5433:5432", "8080:80"]
                if key == "ports", value.hasPrefix("[") {
                    services[last].ports += value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
                } else if !value.isEmpty {
                    services[last].values[key] = value
                }
            } else if section == "environment" {
                services[last].env[key] = value
            }
        }
        return services
    }

    /// The port on this Mac a `ports:` entry publishes `inner` on: "5433:5432", "127.0.0.1:5433:5432", "5432".
    static func published(_ entry: String, inner: Int) -> Int? {
        let parts = entry.split(separator: "/").first.map { $0.split(separator: ":").map(String.init) } ?? []
        guard let target = parts.last.flatMap(Int.init), target == inner else { return nil }
        return parts.count >= 2 ? Int(parts[parts.count - 2]) : nil
    }
}
