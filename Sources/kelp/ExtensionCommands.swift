import Foundation
import Core

extension Main {
    static func ext(_ sub: String?, _ c: RPCClient) async throws {
        switch sub {
        case "list":
            for e in try await IDE.extensions(client: c, dir: Paths.extensions).array ?? [] {
                let tags = [e["builtin"]?.bool == true ? "(built-in)" : nil, e["enabled"]?.bool == false ? "(disabled)" : nil].compactMap { $0 }
                print(([e["id"]?.string ?? "", e["name"]?.string ?? ""] + tags).joined(separator: "\t"))
            }
        case "new":
            let name = flag("--name"), description = flag("--description")
            guard let id = args.first else { fail("ext new <id> [--name N] [--description D]") }
            let folder = try IDE.scaffoldExtension(id: id, name: name, description: description, in: Paths.extensions)
            print("created \(folder.path)\nguide:   \(folder.deletingLastPathComponent().appendingPathComponent("EXTENSIONS.md").path)")
        case "enable", "disable":
            guard let id = args.first else { fail("ext enable|disable <id>") }
            try await IDE.setExtension(id, enabled: sub == "enable", client: c)
        case "reload": show(try .from(try await c.call(UICommand(id: "extensions.reload"))))
        case "path": print(Paths.extensions.path)
        case "search":
            for e in try await c.call(ExtensionLibrary()) where e.matches(args.joined(separator: " ")) {
                print([e.id, e.version, e.name, e.description ?? ""].joined(separator: "\t"))
            }
        case "install":
            guard let what = args.first else { fail("ext install <id | github-url | ./folder>") }
            var dir: ObjCBool = false
            if what.contains("/"), FileManager.default.fileExists(atPath: what, isDirectory: &dir), dir.boolValue {
                let src = URL(fileURLWithPath: what).standardizedFileURL
                installed(try IDE.installExtension(src, as: src.lastPathComponent, in: Paths.extensions))
            } else if what.contains("/") {
                installed(try await fetch(what, as: nil, c, review: !args.contains("--yes")))
            } else {
                guard let e = try await c.call(ExtensionLibrary()).first(where: { $0.id == what }) else { fail("no \(what) in the library (kelp ext search)") }
                installed(try await fetch(e.source, as: nil, c))
            }
        case "update":
            let library = try await c.call(ExtensionLibrary())
            var found = false
            for f in (try? FileManager.default.contentsOfDirectory(at: Paths.extensions, includingPropertiesForKeys: nil)) ?? [] {
                guard let source = IDE.extensionSource(f), let id = manifest(f)["id"]?.string, args.first.map({ $0 == id }) ?? true else { continue }
                found = true
                // One from elsewhere on GitHub may have moved on its branch: it's fetched again.
                let latest = library.first { $0.id == id }?.source
                if latest == source { print("\(id) is up to date"); continue }
                // The library's pinned commit was reviewed; a branch elsewhere may hold anything its owner pushed since.
                installed(try await fetch(latest ?? source, as: f.lastPathComponent, c, review: latest == nil && !args.contains("--yes")))
            }
            if !found { print(args.first.map { "\($0) wasn't installed from GitHub" } ?? "nothing here was installed from GitHub") }
        default: print(usage)
        }
    }

    /// Downloads it through the daemon and moves it in, as `name` (else its id). `review`: what it can run is shown
    /// first and asked about in a terminal; with no terminal to ask in, it's refused (`--yes` says yes).
    static func fetch(_ source: String, as name: String?, _ c: RPCClient, review: Bool = false) async throws -> URL {
        let folder = URL(fileURLWithPath: try await c.call(ExtensionFetch(source: source)).folder)
        if review {
            let (commands, pages) = IDE.commandsIn(manifest(folder))
            if !commands.isEmpty || !pages.isEmpty {
                print("\(source) can run:")
                commands.forEach { print("  \($0)") }
                pages.forEach { print("  \($0) (a web page, which can run any command)") }
                guard isatty(STDIN_FILENO) == 1 else { fail("not installed: run it again with --yes to install it as it is") }
                print("Install it? [y/N] ", terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else { fail("not installed") }
            }
        }
        return try IDE.installExtension(folder, as: name ?? folder.lastPathComponent, in: Paths.extensions, move: true)
    }

    static func manifest(_ folder: URL) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent("extension.json")))) ?? .null
    }

    /// What was installed and what it can run: the CLI's version of the app's look before installing.
    static func installed(_ dest: URL) {
        let m = manifest(dest), (commands, pages) = IDE.commandsIn(m)
        print("installed \(m["id"]?.string ?? dest.lastPathComponent) \(m["version"]?.string ?? "") → \(dest.path)")
        if !commands.isEmpty || !pages.isEmpty { print("it can run:") }
        for x in commands { print("  \(x)") }
        for p in pages { print("  \(p) (a web page, which can run any command)") }
    }
}
