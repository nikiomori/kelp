import Foundation

/// What an agent made for the user to read: a page in `.kelp/artifacts/<slug>/` of the project (its file and
/// `artifact.json`), or a page the agent published on its own service (claude.ai), of which Kelp keeps the link.
public struct ArtifactRecord: Codable, Equatable, Sendable {
    public var type: String
    public var title: String
    public var created: Date
    /// The chat that made it (its KELP_SESSION), for answers and questions to go back to.
    public var session: String?
    /// The page's file in the folder; nil for one on a service.
    public var file: String?
    /// The page on the agent's own service.
    public var url: String?
    /// Its file as each turn of its agent left it, oldest first (`Artifacts.keepVersions`).
    public var versions: [ArtifactVersion]?

    public init(
        type: String, title: String, created: Date, session: String? = nil, file: String? = nil, url: String? = nil,
        versions: [ArtifactVersion]? = nil
    ) {
        self.type = type
        self.title = title
        self.created = created
        self.session = session
        self.file = file
        self.url = url
        self.versions = versions
    }
}

/// An artifact as the Artifacts panel shows it (`ArtifactsEvent`): its record, what opens it, and what its file says now.
public struct ArtifactItem: Codable, Equatable, Sendable {
    public var slug: String, type: String, title: String
    /// Seconds since 1970, as `modified`.
    public var created: Double
    public var session: String?, url: String?
    /// Its file, or its page on the service (`Artifacts.target`).
    public var target: String
    /// A review's points, and how many have a pick.
    public var points: Int?, answered: Int?
    /// When its file was last saved; nil for a page on a service.
    public var modified: Double?
    /// Its kept versions, oldest first; `changed`: the file differs from the last of them (written since, or none kept yet).
    public var versions: [ArtifactVersion]?, changed: Bool?

    public init(
        slug: String, type: String, title: String, created: Double, session: String? = nil, url: String? = nil,
        target: String,
        points: Int? = nil, answered: Int? = nil, modified: Double? = nil
    ) {
        self.slug = slug
        self.type = type
        self.title = title
        self.created = created
        self.session = session
        self.url = url
        self.target = target
        self.points = points
        self.answered = answered
        self.modified = modified
    }
}

public enum Artifacts {
    /// The kinds Kelp makes on this Mac, and the file each one is: Markdown, or a page of HTML for what Markdown can't draw.
    public enum Kind: String, CaseIterable, Sendable {
        case doc, review, slides, design, dashboard
        public var file: String { "\(rawValue).\(isHTML ? "html" : "md")" }
        public var isHTML: Bool { self == .design || self == .dashboard }
    }

    /// Every kind a guide speaks of.
    public static let guides = Kind.allCases.map(\.rawValue)

    public static let folder = ".kelp/artifacts"

    /// The pages an agent's own tools publish. ponytail: one service; a field in the agent manifest once a second has one.
    static var nativePage: Regex<Substring> { /https:\/\/claude\.ai\/artifact\/[A-Za-z0-9_-]+/ }

    public static func dir(root: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(folder) }

    /// A folder name from the title, in Latin letters ("План" → "plan"): lowercase words joined by "-", at most 48
    /// characters; "artifact" for none.
    public static func slug(_ title: String) -> String {
        let latin =
            title.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false)
            ?? title
        let words = latin.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        var joined = ""
        for word in words where joined.count + word.count + 1 <= 48 { joined += (joined.isEmpty ? "" : "-") + word }
        return joined.isEmpty ? "artifact" : joined
    }

    /// A new page of `kind` in `root`'s artifacts: its folder, its first lines and its record. Returns the page's file.
    public static func create(_ kind: Kind, title: String, root: String, session: String?, now: Date = Date()) throws
        -> URL
    {
        let folder = try newFolder(title, root: root)
        let page = folder.appendingPathComponent(kind.file)
        try (kind.isHTML ? htmlStart(title) : "# \(title)\n\n").write(to: page, atomically: true, encoding: .utf8)
        try save(
            ArtifactRecord(type: kind.rawValue, title: title, created: now, session: session, file: kind.file),
            in: folder)
        return page
    }

    /// A page of HTML's first lines: its title, and the system's font in the app's light or dark.
    static func htmlStart(_ title: String) -> String {
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <title>\(escaped)</title>
            <style>
            :root { color-scheme: light dark; }
            body { margin: 0; padding: 32px; font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
            </style>
            </head>
            <body>
            <h1>\(escaped)</h1>
            </body>
            </html>

            """
    }

    /// Keeps the link to a page the agent published on its own service; nil when it's known already (a later version).
    public static func addNative(
        url: String, title: String, type: String, root: String, session: String?, now: Date = Date()
    ) throws -> URL? {
        guard !list(root: root).contains(where: { $0.record.url == url }) else { return nil }
        let folder = try newFolder(title, root: root)
        try save(ArtifactRecord(type: type, title: title, created: now, session: session, url: url), in: folder)
        return folder
    }

    /// The project's artifacts, newest first.
    public static func list(root: String) -> [(slug: String, record: ArtifactRecord)] {
        let base = dir(root: root), fm = FileManager.default
        let names =
            fm.enumerator(at: base, includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        return names.compactMap { name in record(in: base.appendingPathComponent(name)).map { (name, $0) } }
            .sorted { $0.record.created > $1.record.created }
    }

    /// The list as the panel shows it: a review's answers counted from its file, each file's last save.
    public static func items(root: String) -> [ArtifactItem] {
        list(root: root).map { slug, r in
            let target = target(slug, r, root: root)
            var item = ArtifactItem(
                slug: slug, type: r.type, title: r.title, created: r.created.timeIntervalSince1970, session: r.session,
                url: r.url, target: target)
            guard r.url == nil else { return item }
            let page = fileStat(target)
            item.modified = page.map { Double($0.mtime.tv_sec) }
            item.versions = r.versions
            // Every event under the folder lists them all again: a page is read only when its size and time can't tell.
            let last = r.versions?.last.map { versionPath(target: target, $0.n) }.flatMap(fileStat)
            if r.type != Kind.review.rawValue, let page, let last, page.size != last.size || !page.newer(than: last) {
                item.changed = page.size != last.size
                return item
            }
            let text = small(target).map { String(decoding: $0, as: UTF8.self) }
            if r.type == Kind.review.rawValue, let text {
                let points = Review(text).points
                item.points = points.count
                item.answered = points.filter { $0.pick != nil }.count
            }
            item.changed = text != r.versions?.last.flatMap { versionText(target: target, $0.n) }
            return item
        }
    }

    /// The record in an artifact's folder; nil for a folder that isn't one (or a record half-written). A repository can
    /// commit one, so it holds only what Kelp writes: a link to a web page, a file in its own folder.
    public static func record(in folder: URL) -> ArtifactRecord? {
        guard let data = small(folder.appendingPathComponent("artifact.json").path, limit: 1 << 20),
            let record = try? decoder.decode(ArtifactRecord.self, from: data)
        else { return nil }
        if let url = record.url, !url.hasPrefix("https://") { return nil }
        if let file = record.file, file.isEmpty || file.contains("/") || file.hasPrefix(".") { return nil }
        return record
    }

    struct FileStat {
        var size: off_t, mtime: timespec
        func newer(than other: FileStat) -> Bool {
            (mtime.tv_sec, mtime.tv_nsec) > (other.mtime.tv_sec, other.mtime.tv_nsec)
        }
    }
    /// A regular file's size and time of its last write; nil for anything else.
    static func fileStat(_ path: String) -> FileStat? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileStat(size: st.st_size, mtime: st.st_mtimespec)
    }

    /// A regular file's bytes, up to `limit`: nil for a link, a device (`/dev/zero` never ends), a folder, or more.
    static func small(_ path: String, limit: Int = 32 << 20) -> Data? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= limit else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// The file as the project names it (`.kelp/artifacts/<name>/review.md`): what an agent in it reads.
    public static func projectPath(_ path: String) -> String {
        path.range(of: "/\(folder)/").map { String(path[path.index(after: $0.lowerBound)...]) } ?? path
    }

    /// What opens it: its file, or its page on the service.
    public static func target(_ slug: String, _ record: ArtifactRecord, root: String) -> String {
        record.url ?? dir(root: root).appendingPathComponent(slug).appendingPathComponent(record.file ?? "").path
    }

    // MARK: pages agents publish themselves

    /// A page an agent's own tool published (claude-artifacts, Claude Docs), from a PostToolUse hook's payload:
    /// its link, and the title the tool was given. nil for any other tool or event: tools that only read or list
    /// (list_types, list_artifacts, read_artifact) name pages too, the types' own and other people's.
    public static func published(hook payload: JSONValue) -> (url: String, title: String, type: String)? {
        guard payload["hook_event_name"]?.string == "PostToolUse", let tool = payload["tool_name"]?.string,
            tool.hasPrefix("mcp__"),
            publishers.contains(where: tool.hasSuffix), let response = payload["tool_response"]
        else { return nil }
        let unescaped = strings(in: response).joined(separator: "\n")
        guard let url = unescaped.firstMatch(of: nativePage).map({ String($0.output) }) else { return nil }
        let input = payload["tool_input"]
        let title =
            input?["title"]?.string ?? input?["container"]?["create"]?["name"]?.string
            ?? unescaped.firstMatch(of: /\\?"title\\?"\s*:\s*\\?"([^"\\]+)/).map { String($0.output.1) } ?? url
        // Which of claude.ai's types it is, the answer doesn't say; a doc is the Docs connector's.
        let type = payload["tool_name"]?.string?.contains("Claude_Docs") == true ? "doc" : "page"
        return (url, title, type)
    }

    /// The tools that make or change a page: claude-artifacts' and Claude Docs'.
    static let publishers = [
        "__publish_version", "__publish_files", "__edit_version", "Claude_Docs__batch", "Claude_Docs__create",
        "Claude_Docs__update"
    ]

    /// Every string in a value: an MCP answer is text holding JSON, or JSON itself.
    private static func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let text): return [text]
        case .array(let array): return array.flatMap(strings)
        case .object(let fields): return fields.values.flatMap(strings)
        default: return []
        }
    }

    // MARK: the guide an agent reads

    /// What `kelp artifact guide <kind>` prints. `whereTo`: the `artifacts.where` setting ("agent" or "local").
    public static func guide(_ kind: String, whereTo: String) -> String? {
        guard let rules = rules[kind] else { return nil }
        var out = "# Making \(article(kind)) in Kelp\n\n"
        if kind == Kind.review.rawValue {
            out +=
                "Reviews stay in the project, even if you can publish artifacts elsewhere: the user's picks come back to you from the file.\n"
        } else if whereTo == "local" {
            out += "Make it here, on this Mac: don't publish it elsewhere, even if you can.\n"
        } else {
            out +=
                "If you can publish artifacts yourself (claude.ai's claude-artifacts or Claude Docs tools), make it there: "
                + "give the user its link: it opens in their own browser, where they're signed in, and Kelp lists it. "
                + "Use `kelp artifact new` only if you can't, or the user asked to keep it on this Mac.\n"
        }
        out +=
            "\nRun `kelp artifact new \(kind) \"<title>\"`: it prints the file to write, and Kelp shows it beside you as you save.\n"
        return out + "\nRules for \(article(kind)):\n" + rules
    }

    /// The rules alone, as `kelp artifact new` prints them after the file.
    public static func rules(_ kind: Kind) -> String { rules[kind.rawValue] ?? "" }

    private static let rules: [String: String] = [
        "doc": """
        - One H1, the title. Then a `> [!NOTE]` with the answer in two sentences.
        - An H2 per section. Tables for comparisons, ```mermaid blocks for flows.
        - Name code as path:line (Sources/App.swift:88): the user opens it from the page.
        - No HTML, no images from the web.

        """,
        "review": """
        - One H1, the title, and a line on what the choices are for.
        - A point per decision: `## 1. The question`, numbered from 1, at most 9.
        - Its options as `- [ ] A. What it means`, 2 to 4 of them, with a detail on the next line, indented two spaces.
        - Mark at most one option per point `*recommended*`.
        - Then tell the user the page is beside them and end your turn: they answer by number (1A 2B), and their
          picks may arrive as a line like `My answers in <file>: 1A 2B`, with `[x]` on the picked options in the file.

        """,
        "slides": """
        - Markdown. A line `---` with an empty line above and below starts the next slide; the first slide is the title.
        - One idea a slide, at most four bullets; a number that matters on a slide of its own.
        - Kelp shows them as 16:9 slides, one under the next (← → step through them, Print gives a page each).

        """,
        "design": """
        - One HTML file with its CSS inline, no scripts or files from the web; icons as inline SVG.
        - A `<section>` per variant, headed `<h2>A. What it is</h2>`, its screens at their real size, side by side.
        - Each screen in light and dark, side by side, in the project's own colours, type and spacing when it has them.
        - Set a background and its text colour together: the page opens in the app's light or dark.
        - Mark one variant recommended in its heading.

        """,
        "dashboard": """
        - One HTML file with its CSS inline, no scripts or files from the web; charts as inline SVG.
        - Numbers first, as large figures with a label; then charts; then the table they came from.
        - Set a background and its text colour together: the page opens in the app's light or dark.
        - Every number names where it came from (the command you ran, the file you read) and when, beside it or under it.

        """
    ]

    private static func article(_ kind: String) -> String { kind == "slides" ? "slides" : "a \(kind)" }

    // MARK: files

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func save(_ record: ArtifactRecord, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: folder.appendingPathComponent("artifact.json"), options: .atomic)   // the panel reads it meanwhile
    }

    /// `<slug>`, or `<slug>-2`… when taken; the first one also keeps the folder out of git.
    private static func newFolder(_ title: String, root: String) throws -> URL {
        let base = dir(root: root), fm = FileManager.default
        if !fm.fileExists(atPath: base.path) { try excludeFromGit(root: root) }
        let stem = slug(title)
        var name = stem, suffix = 2
        while fm.fileExists(atPath: base.appendingPathComponent(name).path) {
            name = "\(stem)-\(suffix)"
            suffix += 1
        }
        let folder = base.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A line in the repository's own `info/exclude` (never a tracked file): git status stays clean. Removing it shares them.
    static func excludeFromGit(root: String) throws {
        let fm = FileManager.default, dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return }
        var common = dotGit
        if !isDir.boolValue {   // a worktree: "gitdir: <repo>/.git/worktrees/<name>"; exclude lives in <repo>/.git
            let line = fm.contents(atPath: dotGit.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard let match = line.firstMatch(of: /gitdir:\s*(.+)/) else { return }
            let gitdir = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            common = URL(fileURLWithPath: gitdir, relativeTo: URL(fileURLWithPath: root, isDirectory: true))
                .standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
        }
        let exclude = common.appendingPathComponent("info/exclude"), entry = "/\(folder)/"
        let text = fm.contents(atPath: exclude.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard !text.split(separator: "\n").contains(where: { $0 == entry }) else { return }
        try fm.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + entry + "\n").write(
            to: exclude, atomically: true, encoding: .utf8)
    }
}
