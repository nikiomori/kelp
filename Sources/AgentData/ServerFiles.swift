import Core
import Foundation
import os

/// Reads and writes the files that hold MCP servers in the agents' common shape (`{"mcpServers": {name: entry}}`).
/// These are Kelp's own `mcp.json` in its home, for every project, and a project's `.mcp.json`. A file is written
/// whole, and its other keys are kept.
/// Limit: what a server needs to sign in (`env`, `headers`) sits in the file as typed, as in the agents' own files;
/// Kelp's file is readable by the person only.
public enum ServerFiles {
    public static func read(_ file: URL) -> [String: ServerEntry] {
        guard let data = Data(contentsIfAny: file),
            let all = Logger.kelp("addons").attempt(
                "reading \(file.lastPathComponent)",
                {
                    try JSONDecoder().decode(JSONValue.self, from: data)
                }), case .object(let servers)? = all["mcpServers"]
        else { return [:] }
        return servers.compactMapValues { value in
            Logger.kelp("addons").attempt("a server in \(file.lastPathComponent)") {
                try value.decode(ServerEntry.self)
            }
        }
    }

    /// Writes `entry` under `name`, or removes the server when `entry` is nil. The file's other keys and servers stay,
    /// but the server's own entry is replaced whole, so its fields that Kelp doesn't know are dropped.
    public static func write(_ name: String, _ entry: ServerEntry?, to file: URL) throws {
        var all: [String: JSONValue] = [:]
        if let data = Data(contentsIfAny: file) {
            guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
            }
            all = fields
        }
        var servers: [String: JSONValue] = if case .object(let old)? = all["mcpServers"] { old } else { [:] }
        servers[name] = try entry.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
        all["mcpServers"] = .object(servers)
        try Paths.ensure(file.deletingLastPathComponent())
        try (JSONEncoder.pretty.encode(JSONValue.object(all)) + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    /// Builds Codex's command line for `servers` (checked on 0.166, where `-c mcp_servers.<name>={…}` adds a server for
    /// one run). What a server signs in with doesn't go on the command line, where any program can read it. Codex takes
    /// it from the chat's environment by name (`env_vars`, `env_http_headers`), and `environment` holds what to put
    /// there.
    public static func codex(_ servers: [String: ServerEntry]) -> (args: [String], environment: [String: String]) {
        var args: [String] = [], environment: [String: String] = [:]
        for (name, entry) in servers.sorted(by: { $0.key < $1.key }) {
            var fields: [String] = []
            if let url = entry.url {
                fields.append("url=\(ShellQuote.doubleQuoted(url))")
                let headers = (entry.headers ?? [:]).sorted { $0.key < $1.key }.map { header, value -> String in
                    let variable = variable(name, header)
                    environment[variable] = value
                    return "\(ShellQuote.doubleQuoted(header))=\(ShellQuote.doubleQuoted(variable))"
                }
                if !headers.isEmpty { fields.append("env_http_headers={\(headers.joined(separator: ","))}") }
            } else if let command = entry.command {
                fields.append("command=\(ShellQuote.doubleQuoted(command))")
                if let list = entry.args, !list.isEmpty {
                    fields.append("args=[\(list.map(ShellQuote.doubleQuoted).joined(separator: ","))]")
                }
                let names = (entry.env ?? [:]).keys.sorted()
                for key in names { environment[key] = entry.env?[key] }
                if !names.isEmpty {
                    fields.append("env_vars=[\(names.map(ShellQuote.doubleQuoted).joined(separator: ","))]")
                }
            } else {
                continue
            }
            args += ["-c", "mcp_servers.\(name)={\(fields.joined(separator: ","))}"]
        }
        return (args, environment)
    }

    /// Returns the variable that holds a header's value for Codex, such as "KELP_MCP_LINEAR_AUTHORIZATION".
    static func variable(_ server: String, _ header: String) -> String {
        "KELP_MCP_"
            + (server + "_" + header).uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }
}

extension AddonFiles {
    /// Returns the entry for the server `name` in `agent`'s own file, for a chat in `cwd`, so that Kelp can hand it to
    /// the other agents.
    public func entry(_ name: String, of agent: String, cwd: String) -> ServerEntry? {
        switch agent {
        case Session.claudeAgent:
            return ServerFiles.read(claudeJSON)[name]
        case Session.codexAgent:
            return Self.codexEntry(name, in: codexConfig)
        default: return nil
        }
    }

    /// Reads a server's table in a Codex config, as far as Kelp hands it on: `command`, `args`, `url` and the `env`
    /// table.
    static func codexEntry(_ name: String, in text: String) -> ServerEntry? {
        let toml = MiniTOML(text), table = "mcp_servers.\(name).", env = table + "env."
        let vars = toml.pairs.filter { $0.key.hasPrefix(env) }.compactMap { pair in
            (pair.value as? String).map { (String(pair.key.dropFirst(env.count)), $0) }
        }
        let entry = ServerEntry(
            command: toml.string(table + "command"), args: toml.strings(table + "args"),
            env: vars.isEmpty ? nil : Dictionary(vars) { _, new in new }, url: toml.string(table + "url"))
        return entry.command == nil && entry.url == nil ? nil : entry
    }
}
