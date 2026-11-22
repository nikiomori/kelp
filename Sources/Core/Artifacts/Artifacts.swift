import Foundation

/// Something an agent made for the user to read. It is either a page in the project's `.kelp/artifacts/<slug>/` (its
/// file and `artifact.json`), or a page the agent published on its own service (claude.ai), whose link Kelp keeps.
public struct ArtifactRecord: Codable, Equatable, Sendable {
    public var type: String
    public var title: String
    public var created: Date
    /// The chat that made the artifact (its KELP_SESSION), so answers and questions can go back to it.
    public var session: String?
    /// The page's file in the folder. nil for a page on a service.
    public var file: String?
    /// The page on the agent's own service.
    public var url: String?
    /// The page's file as each of the agent's turns left it, oldest first (`Artifacts.keepVersions`).
    public var versions: [ArtifactVersion]?
    /// For a page on a service, when the agent last published it again. nil when it was published only once.
    public var updated: Date?
    /// True for a page on a service that was published before Kelp kept copies. Kelp read the chat's transcript to
    /// recover it (`recoverPages`).
    public var recovered: Bool?

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

/// An artifact as the Artifacts panel shows it (`ArtifactsEvent`): its record, what opens it, and what its file says
/// now.
public struct ArtifactItem: Codable, Equatable, Sendable {
    public var slug: String, type: String, title: String
    /// Seconds since 1970, like `modified`.
    public var created: Double
    public var session: String?, url: String?
    /// The artifact's file, or its page on the service (`Artifacts.target`).
    public var target: String
    /// A review's number of points, and how many of them have a pick.
    public var points: Int?, answered: Int?
    /// When the artifact's file was last saved. nil for a page on a service.
    public var modified: Double?
    /// The kept versions, oldest first. `changed` is true when the file differs from the last kept version, because it
    /// was written since or no version is kept yet.
    public var versions: [ArtifactVersion]?, changed: Bool?
    /// The file the preview shows: the artifact's file, or Kelp's copy of a page on a service (`Artifacts.pageCopy`).
    /// nil when there is nothing to show.
    public var preview: String?
    /// The page's marks that are with an agent, and those waiting for the user's check. nil when there are none.
    public var marks: ArtifactMarkCounts?

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

/// How many of a page's marks are with an agent, how many wait for the user's check, and how many of those have the
/// agent's reply.
public struct ArtifactMarkCounts: Codable, Equatable, Sendable {
    public var sent: Int, check: Int, replies: Int
    public init(sent: Int, check: Int, replies: Int = 0) {
        self.sent = sent
        self.check = check
        self.replies = replies
    }
}

public enum Artifacts {
    /// The kinds of artifact Kelp makes on this Mac: a Markdown file, a canvas of boards, or a motion page (an HTML
    /// page whose CSS animations Kelp plays and records as a video).
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case doc, review, slides, design, dashboard, proof, motion
        public var file: String {
            switch self {
            case .design, .dashboard: "canvas.json"
            case .motion: "motion.html"
            default: "\(rawValue).md"
            }
        }
        /// True for a canvas of boards that Kelp draws (`ArtifactCanvas`), and false for a Markdown page.
        public var isCanvas: Bool { self == .design || self == .dashboard }
    }

    /// Older page files that still open as pages. A design and a dashboard were a single HTML page before canvases
    /// existed.
    public static let olderFiles = ["design.html", "dashboard.html"]

    /// Every kind that has a guide.
    public static let guides = Kind.allCases.map(\.rawValue)

    public static let folder = ".kelp/artifacts"

    /// The links of pages that an agent's own tools publish. Limit: one service is known. Make it a field in the agent
    /// manifest once a second service exists.
    static var nativePage: Regex<Substring> { /https:\/\/claude\.ai\/artifact\/[A-Za-z0-9_-]+/ }

    public static func dir(root: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(folder) }

    /// Returns the project's artifacts, newest first by when each was made.
    public static func list(root: String) -> [(slug: String, record: ArtifactRecord)] {
        let base = dir(root: root), fm = FileManager.default
        let names =
            fm.enumerator(at: base, includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        return names.compactMap { name in record(in: base.appendingPathComponent(name)).map { (name, $0) } }
            .sorted { $0.record.created > $1.record.created }
    }

    /// Reads the record in an artifact's folder, or returns nil for a folder that isn't one (or a half-written record).
    /// A repository can commit a record, so only what Kelp writes is accepted: a link to a web page, or a file in the
    /// artifact's own folder.
    public static func record(in folder: URL) -> ArtifactRecord? {
        guard let data = small(folder.appendingPathComponent("artifact.json").path, limit: 1 << 20),
            let record = try? decoder.decode(ArtifactRecord.self, from: data)
        else { return nil }
        if let url = record.url, !url.hasPrefix("https://") { return nil }
        if let file = record.file, file.isEmpty || file.contains("/") || file.hasPrefix(".") { return nil }
        return record
    }

    package struct FileStat {
        package var size: off_t, mtime: timespec
        package func newer(than other: FileStat) -> Bool {
            (mtime.tv_sec, mtime.tv_nsec) > (other.mtime.tv_sec, other.mtime.tv_nsec)
        }
    }
    /// Returns a regular file's size and the time of its last write, or nil for anything other than a regular file.
    package static func fileStat(_ path: String) -> FileStat? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileStat(size: st.st_size, mtime: st.st_mtimespec)
    }

    /// Returns a regular file's bytes, up to `limit`. nil for a link, a device (`/dev/zero` never ends), a folder, or a
    /// file larger than `limit`.
    package static func small(_ path: String, limit: Int = 32 << 20) -> Data? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= limit else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// Returns the path relative to the project (`.kelp/artifacts/<name>/review.md`), which is what an agent in the
    /// project reads.
    public static func projectPath(_ path: String) -> String {
        path.range(of: "/\(folder)/").map { String(path[path.index(after: $0.lowerBound)...]) } ?? path
    }

    /// Returns what opens the artifact: its file, or its page on the service.
    public static func target(_ slug: String, _ record: ArtifactRecord, root: String) -> String {
        record.url ?? dir(root: root).appendingPathComponent(slug).appendingPathComponent(record.file ?? "").path
    }

    // MARK: pages agents publish themselves

    /// Reads a page that an agent's own tool published (claude-artifacts, Claude Docs) from a PostToolUse hook's
    /// payload. It returns the page's link and the title the tool was given. nil for any other tool or event, because
    /// tools that only read or list (list_types, list_artifacts, read_artifact) name pages too, including the types'
    /// own pages and other people's.
    public static func published(hook payload: JSONValue) -> (
        url: String, title: String, type: String, page: PublishedPage?
    )? {
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
        // The answer doesn't say which of claude.ai's types the artifact is. A doc comes from the Docs connector, and a
        // canvas has its files under project/ (the Design type).
        let sent = sentPage(tool: tool, input: input)
        let type = tool.contains("Claude_Docs") ? "doc" : sent.canvas ? Kind.design.rawValue : "page"
        return (url, title, type, sent.page)
    }

    /// The tools that make or change a page, from claude-artifacts and Claude Docs.
    package static let publishers = [
        "__publish_version", "__publish_files", "__edit_version", "Claude_Docs__batch", "Claude_Docs__create",
        "Claude_Docs__update"
    ]

    /// Whether `server` is an MCP server those tools come from: claude.ai's artifacts, or its docs
    /// ("claude_ai_Claude_Docs").
    package static func publishes(server: String) -> Bool {
        server == "claude-artifacts" || server.hasSuffix("Claude_Docs")
    }

    /// Returns every string in a value, because an MCP answer is either text holding JSON or JSON itself.
    package static func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let text): return [text]
        case .array(let array): return array.flatMap(strings)
        case .object(let fields): return fields.values.flatMap(strings)
        default: return []
        }
    }

    // MARK: the guide an agent reads

    /// Returns what `kelp artifact guide <kind> [part]` prints. `whereTo` is "local" when Settings give Claude Code
    /// Kelp's pages too, and "agent" otherwise. `system` says whether the project has its design system. If it doesn't,
    /// a design's guide says to make it first.
    public static func guide(_ kind: String, whereTo: String, part: String? = nil, system: Bool = false) -> String? {
        let canvas = Kind(rawValue: kind).flatMap { $0.isCanvas ? $0 : nil }
        if let part { return canvas != nil ? designPart(part) : nil }
        guard let rules = canvas.map({ canvasCore($0, system: system) }) ?? rules[kind] else { return nil }
        var out = "# Making \(article(kind)) in Kelp\n\n"
        if kind == Kind.review.rawValue {
            out +=
                "Reviews stay in the project, even if you can publish artifacts elsewhere: the user's picks come back to you from the file.\n"
        } else if kind == Kind.proof.rawValue {
            out +=
                "Proofs stay in the project, even if you can publish artifacts elsewhere: their pictures are files beside the page.\n"
        } else if kind == Kind.motion.rawValue {
            out += "Motion pages stay in the project: Kelp plays them beside you and records them as a video.\n"
        } else if whereTo == "local" {
            out += "Make it here, on this Mac: don't publish it elsewhere, even if you can.\n"
        } else {
            out +=
                "If you can publish artifacts yourself (claude.ai's claude-artifacts or Claude Docs tools), make it there: "
                + "give the user its link: it opens in their own browser, where they're signed in, and Kelp lists it. "
                + "Use `kelp artifact new` only if you can't, or the user asked to keep it on this Mac.\n"
        }
        if canvas != nil { return out + "\n" + rules }
        out +=
            "\nRun `kelp artifact new \(kind) \"<title>\"`: it prints the file to write, and Kelp shows it beside you as you save.\n"
        return out + "\nRules for \(article(kind)):\n" + rules
    }

    /// Returns only the rules, as `kelp artifact new` prints them after the file.
    public static func rules(_ kind: Kind) -> String { rules[kind.rawValue] ?? "" }

    private static let rules: [String: String] = [
        "doc": """
        - One H1, the title. Then a `> [!NOTE]` with the answer in two sentences.
        - An H2 per section. Tables for comparisons, ```mermaid blocks for flows.
        - Name code as path:line (Sources/App.swift:88): the user opens it from the page.
        - No HTML, no images from the web.

        \(marksRule)
        """,
        "review": """
        - One H1, the title, and a line on what the choices are for.
        - A point per decision: `## 1. The question`, numbered from 1, at most 9.
        - Its options as `- [ ] A. What it means`, 2 to 4 of them, with a detail on the next line, indented two spaces.
        - Mark at most one option per point `*recommended*`.
        - Once you've done a point the user picked, end its heading with ✓ (`## 1. The question ✓`): the page shows
          it done.
        - Then tell the user the page is beside them and end your turn: they answer by number (1A 2B), and their
          picks may arrive as a line like `My answers in <file>: 1A 2B`, with `[x]` on the picked options in the file.

        """,
        "slides": """
        - Markdown. A line `---` with an empty line above and below starts the next slide; the first slide is the title.
        - One idea a slide, at most four bullets; a number that matters on a slide of its own.
        - Kelp lays each slide out by what it holds: the first is the title (`# Title`, a line under it); a heading that
          is a number (`## 30 %`, a line under it) is a big number; an image (`![what it shows](chart.png)`, a file
          beside slides.md) sits beside the slide's text; the rest reads as a list. The project's .kelp/design, if it
          has one, gives the accent and the font: no HTML, no colours of your own.
        - Kelp shows them one at a time beside a strip of all (← → step, Present fills the pane, Print gives a page
          each).
        - For a deck in the project's own look, make a design instead: `kelp artifact guide design deck`.

        \(marksRule)
        """,
        "motion": """
        - One HTML page, motion.html: Kelp plays it beside you, frame by frame, and exports it as an MP4. Its scripts
          don't run: everything moves with CSS (@keyframes, transitions as keyframes), which Kelp's timeline drives.
        - The stage is the body: `<body data-duration="8">` (seconds), 1920×1080 unless the body sets `data-width` and
          `data-height` (1080×1920 for a phone video). Give the body its size and `overflow: hidden` in CSS.
        - Time is one timeline from 0: each animation starts at its `animation-delay`, with `animation-fill-mode:
          both`, no `infinite`. A scene is an element with `data-start` and `data-duration` (seconds): Kelp shows it
          only then, and lists it as a scene. Give every scene, and every element that moves or holds text, a
          `data-id` and a `data-title`: the user moves, retimes and retypes them by hand in Kelp's studio, which
          writes `translate`, `animation-delay` and `animation-duration` on the element itself. Keep those, and
          `data-hidden`. A picture or a video with its own `data-start` and `data-duration` is a layer of its own
          for that time (the user drops them in), not a scene.
        - Fonts from the system or files beside the page; images and videos are files beside motion.html. No web
          requests.
        - Tell the user it plays beside them (Space plays, ← → step a frame) and that Export Video in its bar makes
          the MP4.

        """,
        "proof": """
        - For a change you made: what you checked and what you saw, for the user to look at before they commit. Not a
          plan, not a tour of the code.
        - One H1: the change, as the user would name it.
        - `## Checked`: a line per check, the command in backticks and the line of its output that shows the result.
          Only what you ran in this chat; what you couldn't run goes under `## Not checked`, with why.
        - A change that shows on screen has pictures, saved beside proof.md: `kelp browser screenshot <file>` for a
          page, `kelp vm screenshot <name> <file>` for an app in a machine, `kelp shot <file>` for Kelp's own window,
          the project's own tool for anything else. Look at each picture yourself before you put it on the page.
        - Where the look changed, before and after on one line, under a line `Before · After`:
          `<img src="before.png" width="49%"> <img src="after.png" width="49%">` (the only HTML on the page). With no
          picture from before the change, the after alone: `![what it shows](after.png)`.
        - Nothing on screen changed: no pictures.

        """
    ]

    /// What every page that takes marks (a design, a doc, slides) tells the agent about them.
    package static let marksRule = """
        - The user's marks arrive as `Marks on <page> (version N)`, a line each: `#3 boards/A.html [data-id=cta]
          «Start»: bigger`. Change only what each points at, in place; an area or a pen mark comes with a picture:
          read it. The user edits these files by hand too: read a file again before you edit it, and never undo a
          change you didn't make (`Edited by the user` lines name them). If you can't do a mark or need an answer,
          say so with `kelp artifact reply <name> <#> "…"`, one line. You never close a mark: the user checks each
          one. `kelp artifact marks <name>` lists those still open.

        """

    /// A new motion page: a black 1920×1080 stage, five seconds long, for the agent to fill.
    public static func motionStart(_ title: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(BoardEdit.escape(title))</title>
        <style>
        body { margin: 0; width: 1920px; height: 1080px; overflow: hidden; background: #111; color: #fff;
          font: 64px -apple-system, BlinkMacSystemFont, sans-serif; }
        </style></head>
        <body data-duration="5">
        </body></html>

        """
    }

    private static func article(_ kind: String) -> String { kind == "slides" ? "slides" : "a \(kind)" }

    // MARK: files

    package static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
