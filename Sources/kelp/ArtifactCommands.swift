import Core
import Foundation

extension Main {
    /// `artifact guide|new|list|tags|tag|untag|archive|unarchive|sync|open|add|check|links|marks|reply|ask|suggest|
    /// export|beats|captions` handles pages agents make for the user, kept in the project's `.kelp/artifacts`.
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
            let quiet = has("--no-open"), source = flag("--from")
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
            print(file + (try keep(source, beside: file)))
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
        case "list": try await listPages(cwd, c)
        case "tags": try await listTags(cwd, c)
        case "sync": try await sync(cwd, c)
        case "tag", "untag", "archive", "unarchive": try await keep(sub ?? "", cwd, c)
        case "rm", "remove", "delete", "trash":
            fail("Only the user deletes pages. Move it to the archive instead: kelp artifact archive <name>")
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
            // A board is also checked at the phone's and the tablet's widths under its own: `--width` keeps those.
            let width = flag("--width")
            if let width, !["390", "768", "1280"].contains(width) { fail("--width takes 390, 768 or 1280") }
            let root = try await projectRoot(cwd, c)
            guard let name = args.first, let artifact = Artifacts.list(root: root).first(where: { $0.slug == name }),
                artifact.record.file != Artifacts.Kind.review.file
            else {
                fail("artifact check <name of a page other than a review> (names: kelp artifact list)")
            }
            let target = Artifacts.target(artifact.slug, artifact.record, root: root)
            _ = try await IDE.open(target, split: nil, cwd: cwd, client: c)   // The window checks what it draws.
            let all = try await c.call(ArtifactCheck(path: target))
            let issues = width.map { w in all.filter { $0.contains(" @\(w): ") } } ?? all
            print(issues.isEmpty ? "No issues." : issues.map { "- " + $0 }.joined(separator: "\n"))
        case "links": try await links(cwd, c)
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
        case "ask", "suggest": try await talk(sub ?? "", cwd, c)
        case "beats", "captions": try await motion(sub ?? "", cwd, c)
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
    /// `artifact ask <name> <data-id> <question>` puts the agent's question on an element, for the user to answer;
    /// `artifact suggest <name> <request>…` offers up to three things the user may ask for next.
    static func talk(_ sub: String, _ cwd: String, _ client: RPCClient) async throws {
        let ask = sub == "ask"
        let usage =
            ask
            ? "artifact ask <name> <data-id> <your question> [--choice <answer>]…"
            : "artifact suggest <name> \"<request>\" [\"<request>\" …]"
        let choices = ask ? all("--choice") : []   // the user answers with a click, sent at once
        guard args.count >= (ask ? 3 : 2) else { fail(usage) }
        let (target, _) = try await page(args.first, root: try await projectRoot(cwd, client), usage: usage)
        if ask {
            let question = args.dropFirst(2).joined(separator: " ") + choices.map { "\n• " + $0 }.joined()
            let n = try await client.call(ArtifactAsk(path: target, id: args[1], text: question))
            print(
                choices.isEmpty
                    ? "Asked as #\(n) on \(args[1]). The answer comes with the user's next marks."
                    : "Asked as #\(n) on \(args[1]). A click on a choice sends it to you at once.")
        } else {
            _ = try await client.call(ArtifactSuggest(path: target, lines: Array(args.dropFirst().prefix(3))))
            print("Suggested. The user sees them under the marks until the next send.")
        }
    }

    /// `artifact export <name> <format> [to]`: the app draws and writes it (PNG, PDF and PowerPoint need its pages), as
    /// `kelp shot` does.
    static func exportPage(_ cwd: String, _ client: RPCClient) async throws {
        let formats = ["png", "pdf", "pptx", "html", "zip", "docx", "md", "mp4", "gif", "mov"]
        let usage = "artifact export <name> <\(formats.joined(separator: "|"))> [to]"
        guard args.count >= 2, formats.contains(args[1]) else { fail(usage) }
        let (target, _) = try await page(args.first, root: try await projectRoot(cwd, client), usage: usage)
        let to = URL(
            fileURLWithPath: args.count > 2 ? args[2] : args[0] + (args[1] == "png" ? "-boards" : "." + args[1]),
            relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)
        ).standardizedFileURL.path
        _ = try await client.call(
            UICommand(
                id: "artifacts.export",
                args: .object(["path": .string(target), "format": .string(args[1]), "to": .string(to)])))
        guard ["mp4", "gif", "mov"].contains(args[1]) else {
            return print("Exporting to \(to): the app writes it (a folder of boards for png).")
        }
        // A video takes a while: wait for the app's check of the file it made, and print it.
        let check = Artifacts.exportCheck(for: to)
        // An old check of the same file says nothing about this one.
        do { try FileManager.default.removeItem(at: check) } catch CocoaError.fileNoSuchFile {}
        for _ in 0..<1200 {
            if let data = FileManager.default.contents(atPath: check.path) {
                return print(String(decoding: data, as: UTF8.self))
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        fail("Still making \(to) after 10 minutes: see Export Video's list in the page.")
    }

    static func page(_ name: String?, root: String, usage: String) async throws -> (String, ArtifactRecord) {
        guard let name, let artifact = Artifacts.list(root: root).first(where: { $0.slug == name }),
            artifact.record.file != nil
        else { fail("\(usage) (names: kelp artifact list)") }
        return (Artifacts.target(artifact.slug, artifact.record, root: root), artifact.record)
    }

    /// A mark as `kelp artifact marks` lists it: number, state, what it points at, the note it went with, and the
    /// agent's reply.
    static func line(_ mark: ArtifactMark, folder: String) -> String {
        let note = mark.rounds.last?.note ?? mark.note
        var what = [mark.board]
        switch mark.kind {
        case .element: what.append(mark.target)
        case .quote: what.append("«\(mark.text)»")
        case .area: what.append("area " + (mark.area ?? []).map { String(Int($0.rounded())) }.joined(separator: ","))
        case .pen: what.append("pen" + (mark.target.isEmpty ? "" : " near \(mark.target)"))
        }
        if let picture = mark.picture { what.append(folder + "/" + picture) }
        let reply = mark.rounds.last?.reply.map { "  (you said: \($0))" } ?? ""
        let state = mark.state == .check ? "to check" : mark.state.rawValue
        return "#\(mark.id)\t\(state)\t\(what.filter { !$0.isEmpty }.joined(separator: " "))\t\(note)\(reply)"
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
        _ p: (url: String, title: String, type: String, page: PublishedPage?), cwd: String, session: String,
        serviceId: String?
    ) async {
        do {
            _ = try await connect().call(
                ArtifactAdd(
                    url: p.url, title: p.title, type: p.type, cwd: cwd, session: session, page: p.page,
                    serviceId: serviceId))
        } catch {
            let why = (error as? RPCError)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data("kelp: couldn't keep \(p.url): \(why)\n".utf8))
        }
    }

    /// Called from `kelp hook command` after `upload_asset`: keeps the uploaded files, so Kelp's copies of the pages
    /// show them without the network. This never fails the hook either.
    static func keepUploads(_ files: [(path: String, id: String)], cwd: String, session: String) async {
        do {
            let assets = files.map { ArtifactKeepAssets.Asset(path: $0.path, id: $0.id) }
            _ = try await connect().call(ArtifactKeepAssets(cwd: cwd, session: session, assets: assets))
        } catch {
            let why = (error as? RPCError)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data("kelp: couldn't keep the uploaded files: \(why)\n".utf8))
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
