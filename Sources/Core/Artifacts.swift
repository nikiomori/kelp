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

    public init(type: String, title: String, created: Date, session: String? = nil, file: String? = nil, url: String? = nil) {
        self.type = type; self.title = title; self.created = created; self.session = session; self.file = file; self.url = url
    }
}

public enum Artifacts {
    /// The kinds Kelp makes on this Mac, and the file each one is.
    public enum Kind: String, CaseIterable, Sendable {
        case doc, review
        public var file: String { "\(rawValue).md" }
    }

    /// Every kind a guide speaks of: the ones Kelp makes, and those only an agent's own service makes for now.
    public static let guides = Kind.allCases.map(\.rawValue) + ["slides", "design", "dashboard"]

    public static let folder = ".kelp/artifacts"

    /// The pages an agent's own tools publish. ponytail: one service; a field in the agent manifest once a second has one.
    static var nativePage: Regex<Substring> { /https:\/\/claude\.ai\/artifact\/[A-Za-z0-9_-]+/ }

    public static func dir(root: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(folder) }

    /// A folder name from the title, in Latin letters ("План" → "plan"): lowercase words joined by "-", at most 48
    /// characters; "artifact" for none.
    public static func slug(_ title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? title
        let words = latin.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        var s = ""
        for w in words where s.count + w.count + 1 <= 48 { s += (s.isEmpty ? "" : "-") + w }
        return s.isEmpty ? "artifact" : s
    }

    /// A new page of `kind` in `root`'s artifacts: its folder, its first lines and its record. Returns the page's file.
    public static func create(_ kind: Kind, title: String, root: String, session: String?, now: Date = Date()) throws -> URL {
        let folder = try newFolder(title, root: root)
        let page = folder.appendingPathComponent(kind.file)
        try "# \(title)\n\n".write(to: page, atomically: true, encoding: .utf8)
        try save(ArtifactRecord(type: kind.rawValue, title: title, created: now, session: session, file: kind.file), in: folder)
        return page
    }

    /// Keeps the link to a page the agent published on its own service; nil when it's known already (a later version).
    public static func addNative(url: String, title: String, type: String, root: String, session: String?, now: Date = Date()) throws -> URL? {
        guard !list(root: root).contains(where: { $0.record.url == url }) else { return nil }
        let folder = try newFolder(title, root: root)
        try save(ArtifactRecord(type: type, title: title, created: now, session: session, url: url), in: folder)
        return folder
    }

    /// The project's artifacts, newest first.
    public static func list(root: String) -> [(slug: String, record: ArtifactRecord)] {
        let base = dir(root: root), fm = FileManager.default
        let names = fm.enumerator(at: base, includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        return names.compactMap { name in record(in: base.appendingPathComponent(name)).map { (name, $0) } }
            .sorted { $0.record.created > $1.record.created }
    }

    /// The record in an artifact's folder; nil for a folder that isn't one (or a record half-written).
    public static func record(in folder: URL) -> ArtifactRecord? {
        guard let d = FileManager.default.contents(atPath: folder.appendingPathComponent("artifact.json").path) else { return nil }
        return try? decoder.decode(ArtifactRecord.self, from: d)
    }

    /// The file as the project names it (`.kelp/artifacts/<name>/review.md`): what an agent in it reads.
    public static func projectPath(_ path: String) -> String {
        path.range(of: "/\(folder)/").map { String(path[path.index(after: $0.lowerBound)...]) } ?? path
    }

    /// What opens it: its file, or its page on the service.
    public static func target(_ slug: String, _ r: ArtifactRecord, root: String) -> String {
        r.url ?? dir(root: root).appendingPathComponent(slug).appendingPathComponent(r.file ?? "").path
    }

    // MARK: pages agents publish themselves

    /// A page an agent's own tool published (claude-artifacts, Claude Docs), from a PostToolUse hook's payload:
    /// its link, and the title the tool was given. nil for any other tool or event.
    public static func published(hook v: JSONValue) -> (url: String, title: String, type: String)? {
        guard v["hook_event_name"]?.string == "PostToolUse", v["tool_name"]?.string?.hasPrefix("mcp__") == true,
              let response = v["tool_response"] else { return nil }
        let unescaped = strings(in: response).joined(separator: "\n")
        guard let url = unescaped.firstMatch(of: nativePage).map({ String($0.output) }) else { return nil }
        let input = v["tool_input"]
        let title = input?["title"]?.string ?? input?["container"]?["create"]?["name"]?.string
            ?? unescaped.firstMatch(of: /\\?"title\\?"\s*:\s*\\?"([^"\\]+)/).map { String($0.output.1) } ?? url
        // Which of claude.ai's types it is, the answer doesn't say; a doc is the Docs connector's.
        let type = v["tool_name"]?.string?.contains("Claude_Docs") == true ? "doc" : "page"
        return (url, title, type)
    }

    /// Every string in a value: an MCP answer is text holding JSON, or JSON itself.
    private static func strings(in v: JSONValue) -> [String] {
        switch v {
        case .string(let s): return [s]
        case .array(let a): return a.flatMap(strings)
        case .object(let o): return o.values.flatMap(strings)
        default: return []
        }
    }

    // MARK: the guide an agent reads

    /// What `kelp artifact guide <kind>` prints. `whereTo`: the `artifacts.where` setting ("agent" or "local").
    public static func guide(_ kind: String, whereTo: String) -> String? {
        guard let rules = rules[kind] else { return nil }
        let local = Kind(rawValue: kind) != nil
        var out = "# Making \(article(kind)) in Kelp\n\n"
        if kind == Kind.review.rawValue {
            out += "Reviews stay in the project, even if you can publish artifacts elsewhere: the user's picks come back to you from the file.\n"
        } else if whereTo == "local" {
            out += local ? "Make it here, on this Mac: don't publish it elsewhere, even if you can.\n"
                : "The user keeps artifacts on this Mac, and Kelp can't make \(kind) here yet: say so, and offer a doc instead.\n"
        } else {
            out += "If you can publish artifacts yourself (claude.ai's claude-artifacts or Claude Docs tools), make it there: "
                + "give the user its link: it opens in their own browser, where they're signed in, and Kelp lists it. "
                + (local ? "Use `kelp artifact new` only if you can't, or the user asked to keep it on this Mac.\n"
                    : "If you can't, tell the user Kelp can't make \(kind) on this Mac yet, and offer a doc instead.\n")
        }
        if local { out += "\nRun `kelp artifact new \(kind) \"<title>\"`: it prints the file to write, and Kelp shows it beside you as you save.\n" }
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
        "slides": "- Slides split by `---`; one idea a slide, at most four bullets, numbers on a slide of their own.\n",
        "design": "- Each variant its own page at its real size, in the project's design system, in light and dark; one marked recommended.\n",
        "dashboard": "- Every number names where it came from: the command you ran and when.\n"
    ]

    private static func article(_ kind: String) -> String { kind == "slides" ? "slides" : "a \(kind)" }

    // MARK: files

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private static func save(_ r: ArtifactRecord, in folder: URL) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(r).write(to: folder.appendingPathComponent("artifact.json"))
    }

    /// `<slug>`, or `<slug>-2`… when taken; the first one also keeps the folder out of git.
    private static func newFolder(_ title: String, root: String) throws -> URL {
        let base = dir(root: root), fm = FileManager.default
        if !fm.fileExists(atPath: base.path) { try excludeFromGit(root: root) }
        let s = slug(title)
        var name = s, n = 2
        while fm.fileExists(atPath: base.appendingPathComponent(name).path) { name = "\(s)-\(n)"; n += 1 }
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
            guard let m = line.firstMatch(of: /gitdir:\s*(.+)/) else { return }
            let gitdir = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            common = URL(fileURLWithPath: gitdir, relativeTo: URL(fileURLWithPath: root, isDirectory: true))
                .standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
        }
        let exclude = common.appendingPathComponent("info/exclude"), entry = "/\(folder)/"
        let text = fm.contents(atPath: exclude.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard !text.split(separator: "\n").contains(where: { $0 == entry }) else { return }
        try fm.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + entry + "\n").write(to: exclude, atomically: true, encoding: .utf8)
    }
}
