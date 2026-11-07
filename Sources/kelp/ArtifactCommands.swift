import Core
import Foundation

extension Main {
    /// `artifact guide|new|list|open|add`: pages agents make for the user, kept in the project's `.kelp/artifacts`.
    static func artifacts(_ sub: String?, _ c: RPCClient) async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let root = try await projectRoot(cwd, c)
        let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
        switch sub {
        case "guide":
            let whereTo = try await c.call(SettingsGet())["artifacts.where"]?.string ?? "agent"
            guard let kind = args.first, let text = Artifacts.guide(kind, whereTo: whereTo) else {
                fail("artifact guide <\(Artifacts.guides.joined(separator: "|"))>")
            }
            print(text, terminator: "")
        case "new":
            let quiet = has("--no-open")
            guard args.count >= 2, let kind = Artifacts.Kind(rawValue: args[0]) else {
                fail("artifact new <\(Artifacts.Kind.allCases.map(\.rawValue).joined(separator: "|"))> <title>")
            }
            let file = try Artifacts.create(
                kind, title: args.dropFirst().joined(separator: " "), root: root, session: session)
            var opened = false
            if !quiet {
                do {
                    _ = try await IDE.open(file.path, split: nil, cwd: cwd, client: c)
                    opened = true
                } catch {   // the page is made all the same
                    print(
                        "Not opened (\((error as? RPCError)?.message ?? error.localizedDescription)): the user finds it in Kelp's list later."
                    )
                }
            }
            print(file.path)
            print(
                opened
                    ? "Opened beside you. Write the page into that file; the tab updates as you save."
                    : "Write the page into that file.")
            print("\nRules:\n" + Artifacts.rules(kind), terminator: "")
        case "list":
            for (slug, r) in Artifacts.list(root: root) {
                print([slug, r.type, r.title, r.url ?? r.file ?? ""].joined(separator: "\t"))
            }
        case "open":
            guard let name = args.first, let artifact = Artifacts.list(root: root).first(where: { $0.slug == name })
            else {
                fail("artifact open <name> (names: kelp artifact list)")
            }
            if let url = artifact.record.url {
                openInBrowser(url)
            }   // Kelp's tabs aren't signed in to the service
            else {
                _ = try await IDE.open(
                    Artifacts.target(artifact.slug, artifact.record, root: root), split: nil, cwd: cwd, client: c)
            }
        case "add":
            let title = flag("--title"), type = flag("--type") ?? "page"
            guard let url = args.first, url.hasPrefix("https://") else {
                fail("artifact add <url> [--title t] [--type doc|slides|design|dashboard]")
            }
            _ = try Artifacts.addNative(url: url, title: title ?? url, type: type, root: root, session: session)
        default: print(usage)
        }
    }

    /// The folder of the workspace `cwd` is in (artifacts belong to it), else `cwd` itself: a chat outside any project.
    static func projectRoot(_ cwd: String, _ c: RPCClient) async throws -> String {
        try await IDE.workspace(cwd: cwd, client: c)?.path ?? cwd
    }

    /// From `kelp hook command`: a page the agent's own tool just published joins the project's list. It isn't opened:
    /// Kelp's tabs can't sign in to claude.ai (Google refuses embedded views), and the user's browser, which is signed
    /// in, would take the focus; the agent gives its link. Never fails the hook: the agent's tool already did its work.
    static func notePublished(_ p: (url: String, title: String, type: String), cwd: String, session: String) async {
        do {
            let root = try await projectRoot(cwd, try connect())
            _ = try Artifacts.addNative(url: p.url, title: p.title, type: p.type, root: root, session: session)
        } catch {
            let why = (error as? RPCError)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data("kelp: couldn't keep \(p.url): \(why)\n".utf8))
        }
    }

    /// The user's default browser, which is signed in to the service the page is on.
    static func openInBrowser(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        do { try process.run() } catch { fail("couldn't open \(url): \(error.localizedDescription)") }
    }
}
