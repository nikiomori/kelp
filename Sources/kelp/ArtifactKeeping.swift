import Core
import Foundation

/// `kelp artifact list|tags|tag|untag|archive|unarchive|sync`: how an agent finds pages, puts them in order and saves
/// them whole. The tags and
/// the archive go through the daemon, which keeps what each page had before an agent's change, so the user can undo it
/// in Artifacts Overview. Deleting stays the user's.
extension Main {
    /// One page as `list --json` prints it.
    struct Listed: Encodable {
        var name, project, folder, title, kind: String
        var tags: [String], archived: Bool, waits: Bool
        var url, file, session: String?
        var made: Date
    }

    /// `kelp artifact list [--all] [--json] [--tag t] [--archived]`: the project's pages, or every project's with
    /// --all, newest first; archived ones only with --archived.
    static func listPages(_ cwd: String, _ c: RPCClient) async throws {
        let every = has("--all"), json = has("--json"), archived = has("--archived")
        let tag = flag("--tag").flatMap(Artifacts.tag)
        let pages = try await pages(every: every, cwd, c).filter {
            ($0.archived == archived) && (tag.map($0.tags.contains) ?? true)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(pages), as: UTF8.self))
            return
        }
        if pages.isEmpty { print(archived ? "No archived pages." : "No pages.") }
        for p in pages {
            let tags = p.tags.map { "#" + $0 }.joined(separator: " ")
            let place = every ? p.folder : (p.url ?? p.file ?? "")
            print([p.name, p.kind, p.title, tags, p.waits ? "waits for the user" : "", place].joined(separator: "\t"))
        }
    }

    /// `kelp artifact tags [--all]`: the tags in use and how many pages have each, most used first.
    static func listTags(_ cwd: String, _ c: RPCClient) async throws {
        var counts: [String: Int] = [:]
        for page in try await pages(every: has("--all"), cwd, c) { for t in page.tags { counts[t, default: 0] += 1 } }
        if counts.isEmpty { print("No tags yet.") }
        for (t, n) in counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) { print("\(t)\t\(n)") }
    }

    /// `kelp artifact tag <name> +a -b`, `untag <name> a`, `archive <name>…`, `unarchive <name>…`. A name is one from
    /// `list`, or a page's folder (`list --all --json` gives it) for a page in another project.
    static func keep(_ sub: String, _ cwd: String, _ c: RPCClient) async throws {
        let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
        let root = try await projectRoot(cwd, c)
        switch sub {
        case "tag", "untag":
            guard let name = args.first, args.count > 1 else {
                fail("artifact \(sub) <name> <tag>… (tag: +a adds, -b removes; names: kelp artifact list)")
            }
            let words = Array(args.dropFirst())
            let add = sub == "tag" ? words.filter { !$0.hasPrefix("-") }.map { String($0.drop { $0 == "+" }) } : []
            let remove =
                sub == "untag" ? words : words.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) }
            let folder = try folder(name, root: root)
            let tags = try await c.call(ArtifactChange(folder: folder, add: add, remove: remove, session: session))
            print("Tags of \(name): " + (tags.isEmpty ? "none" : tags.joined(separator: ", ")))
        default:
            guard !args.isEmpty else { fail("artifact \(sub) <name>… (names: kelp artifact list)") }
            let archive = sub == "archive"
            for name in args {
                let folder = try folder(name, root: root)
                _ = try await c.call(ArtifactChange(folder: folder, archived: archive, session: session))
            }
            print(
                archive
                    ? "Archived \(args.count) page(s). The user brings them back from Archive in Artifacts Overview."
                    : "Moved \(args.count) page(s) out of the archive.")
        }
    }

    /// The folder of the page `name` names: a page of the project at `root`, or a page's folder given whole.
    private static func folder(_ name: String, root: String) throws -> String {
        if name.contains("/" + Artifacts.folder + "/") { return name }
        guard Artifacts.list(root: root).contains(where: { $0.slug == name }) else {
            fail("No page \(name) in this project (names: kelp artifact list; another project's: list --all --json)")
        }
        return Artifacts.dir(root: root).appendingPathComponent(name).path
    }

    /// This project's folder, or every project's with `every`, with the project's name.
    private static func roots(every: Bool, _ cwd: String, _ c: RPCClient) async throws -> [(
        path: String, project: String
    )] {
        guard every else {
            let root = try await projectRoot(cwd, c)
            return [(root, (root as NSString).lastPathComponent)]
        }
        var roots: [(path: String, project: String)] = []
        let repos = try await c.call(RepoList())
        for w in try await c.call(WorktreeList()) where !w.archived && !roots.contains(where: { $0.path == w.path }) {
            roots.append((w.path, repos.first { $0.id == w.repoId }?.name ?? w.path))
        }
        return roots
    }

    /// `kelp artifact sync [--all] [--check]`: the pages on claude.ai whose copy here isn't whole, and how an agent
    /// with claude.ai's artifact tools saves them to disk. --check counts again once that's done.
    static func sync(_ cwd: String, _ c: RPCClient) async throws {
        let every = has("--all"), check = has("--check")
        _ = has("--plan")
        var all = 0
        var short: [(url: String, folder: String, state: String)] = []
        for root in try await roots(every: every, cwd, c) {
            for (slug, record) in Artifacts.list(root: root.path) where record.url != nil {
                all += 1
                let folder = Artifacts.dir(root: root.path).appendingPathComponent(slug)
                let state = Artifacts.copyState(folder: folder, root: root.path)
                if state != .full { short.append((record.url ?? "", folder.path, state == nil ? "none" : "partial")) }
            }
        }
        print("\(all - short.count) of \(all) pages on claude.ai are whole on this Mac.")
        guard !short.isEmpty else { return }
        if !check {
            print(
                """
                For each page below, with your claude-artifacts tools: list its files (list_files, by its link), then
                save them to disk with read_file's paths, without reading them into the conversation. The page
                (index.html, or project/Main.dc.html for a canvas) goes to <folder>/page.html; every other file to
                <folder>/<the path it is served at>; each uploaded picture (list_assets, read_asset) to
                <folder>/_blob/<its id>. Then run `kelp artifact sync --check\(every ? " --all" : "")`.
                """)
        }
        for page in short { print([page.url, page.state, page.folder].joined(separator: "\t")) }
    }

    /// The pages of this project, or of every project with `every`, newest first.
    private static func pages(every: Bool, _ cwd: String, _ c: RPCClient) async throws -> [Listed] {
        try await roots(every: every, cwd, c).flatMap { root in
            Artifacts.list(root: root.path).map { slug, r in
                let folder = Artifacts.dir(root: root.path).appendingPathComponent(slug)
                return Listed(
                    name: slug, project: root.project, folder: folder.path, title: r.title, kind: r.type,
                    tags: r.tags ?? [], archived: r.archived == true, waits: waits(r, folder: folder), url: r.url,
                    file: r.file.map { folder.appendingPathComponent($0).path }, session: r.session, made: r.created)
            }
        }.sorted { $0.made > $1.made }
    }

    /// Whether the page waits for the user: a review not answered in full, or marks to check.
    private static func waits(_ record: ArtifactRecord, folder: URL) -> Bool {
        let marks = ArtifactMarks.read(
            FileManager.default.contents(atPath: folder.appendingPathComponent(ArtifactMarks.file).path))
        if marks.marks.contains(where: { $0.state == .check }) { return true }
        guard record.type == Artifacts.Kind.review.rawValue, let file = record.file,
            let data = Artifacts.small(folder.appendingPathComponent(file).path)
        else { return false }
        return Review(String(decoding: data, as: UTF8.self)).points.contains { $0.pick == nil }
    }
}
