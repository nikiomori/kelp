import Core
import Foundation

extension Main {
    /// `artifact guide|new|list|open|add`: pages agents make for the user, kept in the project's `.kelp/artifacts`.
    static func artifacts(_ sub: String?, _ c: RPCClient) async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
        switch sub {
        case "guide":
            let whereTo = try await SettingKeys.artifactsWhere.read(in: c.call(SettingsGet()))
            let root = try await projectRoot(cwd, c)
            let system = FileManager.default.fileExists(
                atPath: DesignSystem.dir(root: root).appendingPathComponent("kit.css").path)
            guard let kind = args.first,
                let text = Artifacts.guide(kind, whereTo: whereTo, part: args.dropFirst().first, system: system)
            else {
                fail(
                    "artifact guide <\(Artifacts.guides.joined(separator: "|"))> "
                        + "(design parts: \(Artifacts.designParts.joined(separator: "|")))")
            }
            print(text, terminator: "")
        case "new":
            let quiet = has("--no-open")
            guard args.count >= 2, let kind = Artifacts.Kind(rawValue: args[0]) else {
                fail("artifact new <\(Artifacts.Kind.allCases.map(\.rawValue).joined(separator: "|"))> <title>")
            }
            let file = try await c.call(
                ArtifactNew(kind: kind, title: args.dropFirst().joined(separator: " "), cwd: cwd, session: session))
            var opened = false
            if !quiet {
                do {
                    _ = try await IDE.open(file, split: nil, cwd: cwd, client: c)
                    opened = true
                } catch {   // the page is made all the same
                    print(
                        "Not opened (\((error as? RPCError)?.message ?? error.localizedDescription)): the user finds it in Kelp's list later."
                    )
                }
            }
            print(file)
            if kind == .design {
                let folder = (file as NSString).deletingLastPathComponent
                let system = DesignSystem.dir(root: try await projectRoot(cwd, c)).path
                print("Boards: \(folder)/boards/ · design system: \(system)/")
                print(opened ? "Opened beside you; it redraws as you save." : "Write the boards, then canvas.json.")
                let name = (folder as NSString).lastPathComponent
                print(
                    "Rules: `kelp artifact guide design` (skip if you've read it). "
                        + "Check: `kelp artifact check \(name)`."
                )
                return
            }
            print(
                opened
                    ? "Opened beside you. Write the page into that file; the tab updates as you save."
                    : "Write the page into that file.")
            print("\nRules:\n" + Artifacts.rules(kind), terminator: "")
        case "list":
            for (slug, r) in Artifacts.list(root: try await projectRoot(cwd, c)) {
                print([slug, r.type, r.title, r.url ?? r.file ?? ""].joined(separator: "\t"))
            }
        case "open":
            let root = try await projectRoot(cwd, c)
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
        case "check":
            let root = try await projectRoot(cwd, c)
            guard let name = args.first, let artifact = Artifacts.list(root: root).first(where: { $0.slug == name }),
                artifact.record.file == Artifacts.Kind.design.file
            else {
                fail("artifact check <name of a design> (names: kelp artifact list)")
            }
            let target = Artifacts.target(artifact.slug, artifact.record, root: root)
            _ = try await IDE.open(target, split: nil, cwd: cwd, client: c)   // the window checks what it draws
            let issues = try await c.call(ArtifactCheck(path: target))
            print(issues.isEmpty ? "No issues." : issues.map { "- " + $0 }.joined(separator: "\n"))
        case "add":
            let title = flag("--title"), type = flag("--type") ?? "page"
            guard let url = args.first, url.hasPrefix("https://") else {
                fail("artifact add <url> [--title t] [--type doc|slides|design|dashboard]")
            }
            _ = try await c.call(ArtifactAdd(url: url, title: title ?? url, type: type, cwd: cwd, session: session))
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
    static func notePublished(
        _ p: (url: String, title: String, type: String, page: PublishedPage?), cwd: String, session: String
    ) async {
        do {
            _ = try await connect().call(
                ArtifactAdd(url: p.url, title: p.title, type: p.type, cwd: cwd, session: session, page: p.page))
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
