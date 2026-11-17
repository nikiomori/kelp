import Core
import Foundation

extension Main {
    /// `open <path|url> [--split right|down] [--focus]` opens a tab in the app.
    static func open(_ sub: String?, _ c: RPCClient) async throws {
        let split = flag("--split")
        let focus = has("--focus") || sub == "--focus"
        guard let target = sub.flatMap({ $0 == "--focus" ? nil : $0 }) ?? args.first else {
            fail("open <path|url> [--split right|down] [--focus]")
        }
        let cwd = FileManager.default.currentDirectoryPath
        show(try await IDE.open(target, split: split, cwd: cwd, focus: focus, client: c))
    }

    /// `shot [file]` saves the open window as a PNG for an agent to look at. The app writes the file, so this waits for
    /// it.
    static func shot(_ file: String?, _ client: RPCClient) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kelp-shot-\(UUID().uuidString.prefix(8)).png")
        let url = file.map { URL(fileURLWithPath: $0) } ?? temporary, asked = Date().timeIntervalSince1970
        _ = try await client.call(UICommand(id: "window.shot", args: .object(["path": .string(url.path)])))
        for _ in 0..<50 {
            if FileManager.default.modified(url.path)?.timeIntervalSince1970 ?? 0 >= asked {
                print(url.path)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        fail("the app wrote no \(url.path)")
    }

    static func settingsAndUI(_ cmd: String, _ sub: String?, _ client: RPCClient) async throws {
        switch (cmd, sub) {
        case ("settings", nil): show(.object(try await client.call(SettingsGet())))
        case ("settings", "get"):
            guard let key = args.first else { fail("settings get <key>") }
            show(try await client.call(SettingsGet())[key] ?? .null)
        case ("settings", "set"):
            guard args.count >= 2 else { fail("settings set <key> <value>") }
            _ = try await client.call(
                SettingsSet(key: args[0], value: jsonOrText(args.dropFirst().joined(separator: " "))))
        case ("settings", "unset"):
            guard let key = args.first else { fail("settings unset <key>") }
            _ = try await client.call(SettingsSet(key: key, value: nil))
        case ("ui", "state"): show(try await client.call(UIStateGet()))
        case ("run", let id?):
            show(
                try .from(
                    try await client.call(
                        UICommand(id: id, args: args.isEmpty ? nil : jsonOrText(args.joined(separator: " "))))))
        default: print(usage)
        }
    }

    /// `call <method> [json-params]`: calls any of the daemon's methods by name, for one with no command of its own.
    /// The daemon holds every caller to its rules, so a program an agent runs can't reach more through this than
    /// through any other command.
    static func call(_ method: String?, _ client: RPCClient) async throws {
        guard let method else { fail("call <method> [json-params]   (names from `kelp schema`)") }
        let text = args.joined(separator: " ")
        let params = text.isEmpty ? nil : jsonOrText(text)
        switch params {
        case nil, .object?, .array?: show(try await client.call(method, params))
        default: fail("call: the params are a JSON object, as `kelp schema \(method)` shows them")
        }
    }
}
