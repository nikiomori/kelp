import Core
import Foundation

// The Docker side of databases: running containers of database images, their passwords, docker itself.

extension Databases {
    /// Running containers of Postgres, MySQL or MariaDB images that publish their port, as this Mac reaches them.
    /// Docker not running: none.
    func containers() async throws -> [RunningDatabase] {
        try await offloads.run {
            guard let docker = Self.docker(),
                let listed = Subprocess.printed(
                    [docker, "ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}"],
                    path: "/usr/local/bin:/usr/bin:/bin", timeout: 10)
            else { return [] }
            return listed.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 4, let engine = DatabaseInfo.Engine(image: fields[2]) else { return nil }
                guard let inside = engine.defaultPort, let port = Self.published(fields[3], inside) else { return nil }
                let env = Self.environment(docker, fields[0])
                var db = DatabaseInfo(name: fields[1], engine: engine, host: "localhost", port: port)
                if engine == .postgres {
                    db.user = env["POSTGRES_USER"] ?? "postgres"
                    db.database = env["POSTGRES_DB"] ?? db.user
                } else {
                    db.user = env["MYSQL_USER"] ?? env["MARIADB_USER"] ?? "root"
                    db.database = env["MYSQL_DATABASE"] ?? env["MARIADB_DATABASE"]
                }
                db.name = db.database ?? fields[1]
                return RunningDatabase(container: fields[0], name: fields[1], image: fields[2], database: db)
            }
        }
    }

    /// The password a container's environment gives its user: what `db.save` keeps for one picked from `containers`.
    func containerPassword(_ container: String, _ engine: DatabaseInfo.Engine) throws -> String? {
        guard let docker = Self.docker() else { throw RPCError.invalidParams("Docker isn't installed.") }
        let env = Self.environment(docker, container)
        if engine == .postgres { return env["POSTGRES_PASSWORD"] }
        let root = (env["MYSQL_USER"] ?? env["MARIADB_USER"]) == nil
        return root
            ? env["MYSQL_ROOT_PASSWORD"] ?? env["MARIADB_ROOT_PASSWORD"]
            : env["MYSQL_PASSWORD"] ?? env["MARIADB_PASSWORD"]
    }

    /// Where docker is kept when it isn't on the login PATH.
    static let dockerFolders = [
        "/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin"
    ]

    static func docker() -> String? {
        do { return try DatabaseEngines.client("docker", also: dockerFolders) } catch { return nil }
    }

    /// The container compose runs the service in now (`docker compose ps -q`); nil when none runs it.
    static func container(_ service: ComposeService, docker: String) -> String? {
        let id = Subprocess.printed(
            [docker, "compose", "-f", service.file, "ps", "-q", service.name], path: "/usr/local/bin:/usr/bin:/bin",
            timeout: DatabaseTimes.compose)?.split(whereSeparator: \.isNewline).first.map(String.init)
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "0.0.0.0:55432->5432/tcp, [::]:55432->5432/tcp": the port on this Mac for `inside`.
    static func published(_ ports: String, _ inside: Int) -> Int? {
        for part in ports.split(separator: ",") where part.hasSuffix("->\(inside)/tcp") {
            let host = part.split(separator: "-").first?.split(separator: ":").last
            if let port = host.flatMap({ Int($0) }) { return port }
        }
        return nil
    }

    private static func environment(_ docker: String, _ container: String) -> [String: String] {
        let printed =
            Subprocess.printed(
                [docker, "inspect", "--format", "{{range .Config.Env}}{{println .}}{{end}}", container],
                path: "/usr/local/bin:/usr/bin:/bin", timeout: 10) ?? ""
        var env: [String: String] = [:]
        for line in printed.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return env
    }
}
