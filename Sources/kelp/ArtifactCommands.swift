import Core
import Foundation

extension Main {
    /// `artifact guide|new|list|open|add|marks|reply|export` handles pages agents make for the user, kept in the
    /// project's `.kelp/artifacts`.
    static func artifacts(_ sub: String?, _ c: RPCClient) async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
        switch sub {
        case "guide":
            let whereTo =
                try await SettingKeys.skillArtifacts.read(in: c.call(SettingsGet())) == "all" ? "local" : "agent"
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
                } catch {   // The page is made all the same.
                    print(
                        "Not opened (\((error as? RPCError)?.message ?? error.localizedDescription)): the user finds it in Kelp's list later."
                    )
                }
            }
            print(file)
            if kind.isCanvas {
                let folder = (file as NSString).deletingLastPathComponent
                let system = DesignSystem.dir(root: try await projectRoot(cwd, c)).path
                print("Boards: \(folder)/boards/ · design system: \(system)/")
                print(opened ? "Opened beside you; it redraws as you save." : "Write the boards, then canvas.json.")
                let name = (folder as NSString).lastPathComponent
                print(
                    "Rules: `kelp artifact guide \(kind.rawValue)` (skip if you've read it). "
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
            }   // Opened in the browser, because Kelp's tabs aren't signed in to the service.
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
            _ = try await IDE.open(target, split: nil, cwd: cwd, client: c)   // The window checks what it draws.
            let issues = try await c.call(ArtifactCheck(path: target))
            print(issues.isEmpty ? "No issues." : issues.map { "- " + $0 }.joined(separator: "\n"))
        case "marks": try await listMarks(root: try await projectRoot(cwd, c))
        case "reply":
            let usage = "artifact reply <name> <#> <what you say about that mark>"
            guard args.count >= 3, let id = Int(args[1].trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else {
                fail(usage)
            }
            let (target, _) = try await page(args.first, root: try await projectRoot(cwd, c), usage: usage)
            _ = try await c.call(ArtifactReply(path: target, id: id, text: args.dropFirst(2).joined(separator: " ")))
            print("Said on #\(id). The user sees it under the mark.")
        case "add":
            let title = flag("--title"), type = flag("--type") ?? "page"
            guard let url = args.first, url.hasPrefix("https://") else {
                fail("artifact add <url> [--title t] [--type doc|slides|design|dashboard]")
            }
            _ = try await c.call(ArtifactAdd(url: url, title: title ?? url, type: type, cwd: cwd, session: session))
        case "export": try await exportPage(cwd, c)
        default: print(usage)
        }
    }

    /// `kelp artifact marks <name> [--all]`: the marks with an agent and those the user checks; all with --all.
    static func listMarks(root: String) async throws {
        let all = has("--all")   // read once: it takes the flag out of the arguments
        let (target, _) = try await page(args.first, root: root, usage: "artifact marks <name> [--all]")
        let folder = URL(fileURLWithPath: target).deletingLastPathComponent()
        let marks = ArtifactMarks.read(
            FileManager.default.contents(atPath: folder.appendingPathComponent(ArtifactMarks.file).path))
        let shown = marks.marks.filter { all || $0.state == .sent || $0.state == .check }
        if shown.isEmpty { print(all ? "No marks." : "No marks open: none with you, none to check.") }
        for m in shown { print(line(m, folder: Artifacts.projectPath(folder.path))) }
    }

    /// Returns the file of the page named `name` in the project at `root`, or ends with `usage`.
    /// `artifact export <name> <format> [to]`: the app draws and writes it (PNG, PDF and PowerPoint need its pages), as
    /// `kelp shot` does.
    static func exportPage(_ cwd: String, _ c: RPCClient) async throws {
        let formats = ["png", "pdf", "pptx", "html", "zip"]
        let usage = "artifact export <name> <\(formats.joined(separator: "|"))> [to]"
        guard args.count >= 2, formats.contains(args[1]) else { fail(usage) }
        let (target, _) = try await page(args.first, root: try await projectRoot(cwd, c), usage: usage)
        let to = URL(
            fileURLWithPath: args.count > 2 ? args[2] : args[0] + (args[1] == "png" ? "-boards" : "." + args[1]),
            relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)
        ).standardizedFileURL.path
        _ = try await c.call(
            UICommand(
                id: "artifacts.export",
                args: .object(["path": .string(target), "format": .string(args[1]), "to": .string(to)])))
        print("Exporting to \(to): the app writes it (a folder of boards for png).")
    }

    static func page(_ name: String?, root: String, usage: String) async throws -> (String, ArtifactRecord) {
        guard let name, let artifact = Artifacts.list(root: root).first(where: { $0.slug == name }),
            artifact.record.file != nil
        else { fail("\(usage) (names: kelp artifact list)") }
        return (Artifacts.target(artifact.slug, artifact.record, root: root), artifact.record)
    }

    /// A mark as `kelp artifact marks` lists it: number, state, what it points at, the note it went with, and the
    /// agent's reply.
    static func line(_ m: ArtifactMark, folder: String) -> String {
        let note = m.rounds.last?.note ?? m.note
        var what = [m.board]
        switch m.kind {
        case .element: what.append(m.target)
        case .quote: what.append("«\(m.text)»")
        case .area: what.append("area " + (m.area ?? []).map { String(Int($0.rounded())) }.joined(separator: ","))
        case .pen: what.append("pen" + (m.target.isEmpty ? "" : " near \(m.target)"))
        }
        if let picture = m.picture { what.append(folder + "/" + picture) }
        let reply = m.rounds.last?.reply.map { "  (you said: \($0))" } ?? ""
        let state = m.state == .check ? "to check" : m.state.rawValue
        return "#\(m.id)\t\(state)\t\(what.filter { !$0.isEmpty }.joined(separator: " "))\t\(note)\(reply)"
    }

    /// Returns the folder of the workspace that holds `cwd`, because artifacts belong to the workspace. For a chat
    /// outside any project, it returns `cwd` itself.
    static func projectRoot(_ cwd: String, _ c: RPCClient) async throws -> String {
        try await IDE.workspace(cwd: cwd, client: c)?.path ?? cwd
    }

    /// Called from `kelp hook command`: adds a page that the agent's own tool just published to the project's list. The
    /// page isn't opened, because Kelp's tabs can't sign in to claude.ai (Google refuses embedded views), and the
    /// user's signed-in browser would take the focus. The agent gives the link instead. This never fails the hook,
    /// because the agent's tool already did its work.
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

    /// Opens `url` in the user's default browser, which is signed in to the service the page is on.
    static func openInBrowser(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        do { try process.run() } catch { fail("couldn't open \(url): \(error.localizedDescription)") }
    }
}
