import Foundation
import Core

extension Main {
    /// `open <path|url> [--split right|down] [--focus]`: a tab in the app.
    static func open(_ sub: String?, _ c: RPCClient) async throws {
        let split = flag("--split")
        let focus = has("--focus") || sub == "--focus"
        guard let target = sub.flatMap({ $0 == "--focus" ? nil : $0 }) ?? args.first else { fail("open <path|url> [--split right|down] [--focus]") }
        let cwd = FileManager.default.currentDirectoryPath
        show(try await IDE.open(target, split: split, cwd: cwd, focus: focus, client: c))
    }

    static func settingsAndUI(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("settings", nil): show(.object(try await c.call(SettingsGet())))
        case ("settings", "get"):
            guard let k = args.first else { fail("settings get <key>") }
            show(try await c.call(SettingsGet())[k] ?? .null)
        case ("settings", "set"):
            guard args.count >= 2 else { fail("settings set <key> <value>") }
            _ = try await c.call(SettingsSet(key: args[0], value: jsonOrText(args.dropFirst().joined(separator: " "))))
        case ("settings", "unset"):
            guard let k = args.first else { fail("settings unset <key>") }
            _ = try await c.call(SettingsSet(key: k, value: nil))
        case ("ui", "state"): show(try await c.call(UIStateGet()))
        case ("run", let id?):
            show(try .from(try await c.call(UICommand(id: id, args: args.isEmpty ? nil : jsonOrText(args.joined(separator: " "))))))
        default: print(usage)
        }
    }
}
