import Core
import Foundation
import os

/// The files MCP servers are kept in, in the agents' common shape (`{"mcpServers": {name: entry}}`): Kelp's own
/// (`mcp.json` in its home, for every project) and a project's `.mcp.json`. Written whole, other keys kept.
/// Limit: what a server needs to sign in (`env`, `headers`) sits in the file as typed, as in the agents' own files;
/// Kelp's is readable by the person only.
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

    /// `entry` under `name` (nil takes it out). The file's other keys, and a server's fields Kelp doesn't know, stay.
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try Paths.ensure(file.deletingLastPathComponent())
        try (encoder.encode(JSONValue.object(all)) + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    /// Codex's command line for `servers` (verified on 0.166: `-c mcp_servers.<name>={…}` adds one for the run). What a
    /// server signs in with doesn't go on the command line, where any program can read it: Codex takes it from the
    /// chat's environment by name (`env_vars`, `env_http_headers`), and `environment` is what to put there.
    public static func codex(_ servers: [String: ServerEntry]) -> (args: [String], environment: [String: String]) {
        var args: [String] = [], environment: [String: String] = [:]
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        for (name, entry) in servers.sorted(by: { $0.key < $1.key }) {
            var fields: [String] = []
            if let url = entry.url {
                fields.append("url=\(quoted(url))")
                let headers = (entry.headers ?? [:]).sorted { $0.key < $1.key }.map { header, value -> String in
                    let variable = variable(name, header)
                    environment[variable] = value
                    return "\(quoted(header))=\(quoted(variable))"
                }
                if !headers.isEmpty { fields.append("env_http_headers={\(headers.joined(separator: ","))}") }
            } else if let command = entry.command {
                fields.append("command=\(quoted(command))")
                if let list = entry.args, !list.isEmpty {
                    fields.append("args=[\(list.map(quoted).joined(separator: ","))]")
                }
                let names = (entry.env ?? [:]).keys.sorted()
                for key in names { environment[key] = entry.env?[key] }
                if !names.isEmpty { fields.append("env_vars=[\(names.map(quoted).joined(separator: ","))]") }
            } else {
                continue
            }
            args += ["-c", "mcp_servers.\(name)={\(fields.joined(separator: ","))}"]
        }
        return (args, environment)
    }

    /// "KELP_MCP_LINEAR_AUTHORIZATION": the variable a header's value waits in.
    static func variable(_ server: String, _ header: String) -> String {
        "KELP_MCP_"
            + (server + "_" + header).uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }
}

extension AddonFiles {
    /// The entry `agent`'s own file has for the server `name` in a chat in `cwd`: for handing it to the other agents.
    public func entry(_ name: String, of agent: String, cwd: String) -> ServerEntry? {
        switch agent {
        case "claude":
            let own = claude.appendingPathComponent(".claude.json")
            let file =
                FileManager.default.fileExists(atPath: own.path) ? own : home.appendingPathComponent(".claude.json")
            return ServerFiles.read(file)[name]
        case "codex":
            let text = Data(contentsIfAny: codex.appendingPathComponent("config.toml")).map {
                String(decoding: $0, as: UTF8.self)
            }
            return Self.codexEntry(name, in: text ?? "")
        default: return nil
        }
    }

    /// A server's table in a Codex config, read as far as Kelp hands on: `command`, `args`, `url` and its `env` table.
    /// Limit: one-line values only, as Codex itself writes them.
    static func codexEntry(_ name: String, in toml: String) -> ServerEntry? {
        var entry = ServerEntry(), table = ""
        func string(_ raw: String) -> String {
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2, let quote = text.first, quote == "\"" || quote == "'", text.last == quote else {
                return text
            }
            let inner = String(text.dropFirst().dropLast())
            return quote == "'"
                ? inner
                : inner.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
        }
        for raw in toml.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).replacingOccurrences(
                    of: "\"", with: "")
                continue
            }
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = string(String(line[..<equals])), value = String(line[line.index(after: equals)...])
            if table == "mcp_servers.\(name)" {
                switch key {
                case "command": entry.command = string(value)
                case "url": entry.url = string(value)
                case "args":
                    let inner = value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    entry.args = inner.isEmpty ? [] : inner.split(separator: ",").map { string(String($0)) }
                default: break
                }
            } else if table == "mcp_servers.\(name).env" {
                entry.env = (entry.env ?? [:]).merging([key: string(value)]) { _, new in new }
            }
        }
        return entry.command == nil && entry.url == nil ? nil : entry
    }
}
