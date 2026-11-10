import Core
import Foundation

extension Main {
    static func ext(_ sub: String?, _ c: RPCClient) async throws {
        switch sub {
        case "list":
            for e in try await ExtensionFiles.extensions(client: c, dir: Paths.extensions) {
                let tags = [
                    e.builtin ? "(built-in)" : nil, e.enabled ? nil : "(disabled)", e.error.map { "error: \($0)" }
                ].compactMap { $0 }
                print(([e.id, e.name] + tags).joined(separator: "\t"))
            }
        case "new":
            let name = flag("--name"), description = flag("--description")
            guard let id = args.first else { fail("ext new <id> [--name N] [--description D]") }
            let folder = try ExtensionFiles.scaffoldExtension(
                id: id, name: name, description: description, in: Paths.extensions)
            print(
                "created \(folder.path)\nguide:   \(folder.deletingLastPathComponent().appendingPathComponent("EXTENSIONS.md").path)"
            )
        case "enable", "disable":
            guard let id = args.first else { fail("ext enable|disable <id>") }
            try await ExtensionFiles.setExtension(id, enabled: sub == "enable", client: c)
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
                installed(try ExtensionFiles.installExtension(src, as: src.lastPathComponent, in: Paths.extensions))
            } else if what.contains("/") {
                installed(try await fetch(what, as: nil, c, review: !args.contains("--yes")))
            } else {
                guard let entry = try await c.call(ExtensionLibrary()).first(where: { $0.id == what }) else {
                    fail("no \(what) in the library (kelp ext search)")
                }
                // Found by its topic, never reviewed: shown first, as any repository is.
                installed(
                    try await fetch(
                        entry.source, as: nil, c, review: entry.reviewed == false && !args.contains("--yes"),
                        files: entry.files))
            }
        case "update":
            let library = try await c.call(ExtensionLibrary())
            var found = false
            for f in FileManager.default.items(in: Paths.extensions) {
                guard let source = ExtensionFiles.extensionSource(f), let id = manifest(f)["id"]?.string,
                    args.first.map({ $0 == id }) ?? true
                else { continue }
                found = true
                // One from elsewhere on GitHub may have moved on its branch: it's fetched again.
                let entry = library.first { $0.id == id }, latest = entry?.source
                // A pinned commit (reviewed) says whether it changed; a repository found by its topic is a branch: fetched again.
                if latest == source, entry?.reviewed != false {
                    print("\(id) is up to date")
                    continue
                }
                // The library's pinned commit was reviewed; a branch elsewhere may hold anything its owner pushed since. Either
                // way, commands it didn't run before are asked about.
                installed(
                    try await fetch(
                        latest ?? source, as: f.lastPathComponent, c,
                        review: (latest == nil || entry?.reviewed == false)
                            && !args.contains("--yes"), files: entry?.files, before: args.contains("--yes") ? nil : f))
            }
            if !found {
                print(
                    args.first.map { "\($0) wasn't installed from GitHub" } ?? "nothing here was installed from GitHub")
            }
        default: print(usage)
        }
    }

    /// Downloads it through the daemon and moves it in, as `name` (else its id). `review`: what it can run is shown
    /// first and asked about in a terminal; with no terminal to ask in, it's refused (`--yes` says yes).
    /// `files`: the library's SHA-256 of each, which the download must match. `before`: the version installed now; commands
    /// the new one runs that it didn't are asked about even when the rest needs no review.
    static func fetch(
        _ source: String, as name: String?, _ c: RPCClient, review: Bool = false, files: [String: String]? = nil,
        before: URL? = nil
    ) async throws -> URL {
        let folder = URL(fileURLWithPath: try await c.call(ExtensionFetch(source: source, files: files)).folder)
        let had = before.map { ExtensionFiles.commandsIn(manifest($0)) }
        var (commands, pages) = ExtensionFiles.commandsIn(manifest(folder))
        if !review, let had {   // an update: only what's new needs a yes
            commands = commands.filter { !had.commands.contains($0) }
            pages = pages.filter { !had.pages.contains($0) }
        }
        if review || had != nil {
            if !commands.isEmpty || !pages.isEmpty {
                print(had != nil && !review ? "\(source) now also runs:" : "\(source) can run:")
                commands.forEach { print("  \($0)") }
                pages.forEach { print("  \($0) (a web page, which can run any command)") }
                guard isatty(STDIN_FILENO) == 1 else {
                    fail("not installed: run it again with --yes to install it as it is")
                }
                print("Install it? [y/N] ", terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else { fail("not installed") }
            }
        }
        return try ExtensionFiles.installExtension(
            folder, as: name ?? folder.lastPathComponent, in: Paths.extensions, move: true)
    }

    static func manifest(_ folder: URL) -> JSONValue {
        (try? JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent("extension.json")))) ?? .null
    }

    /// What was installed and what it can run: the CLI's version of the app's look before installing.
    static func installed(_ dest: URL) {
        let info = manifest(dest), (commands, pages) = ExtensionFiles.commandsIn(info)
        print(
            "installed \(info["id"]?.string ?? dest.lastPathComponent) \(info["version"]?.string ?? "") → \(dest.path)")
        if !commands.isEmpty || !pages.isEmpty { print("it can run:") }
        for x in commands { print("  \(x)") }
        for p in pages { print("  \(p) (a web page, which can run any command)") }
    }
}
