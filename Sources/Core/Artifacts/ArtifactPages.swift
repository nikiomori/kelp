import Foundation

/// The page content that a publishing tool sent. Kelp keeps a copy of it beside the link, for the panel's preview,
/// because Kelp's tabs can't sign in to the service and so can't show the page there.
public struct PublishedPage: Codable, Equatable, Sendable {
    /// The whole page (`publish_version`).
    public var html: String?
    /// A file on this Mac that holds the page (for `publish_files`, its index.html or a canvas's first board).
    public var file: String?
    /// Changes to the last version (`edit_version`), which are applied to the copy.
    public var edits: [Edit]?
    /// The other files `publish_files` sent beside the page (its CSS, scripts, pictures): where each is served, and the
    /// file on this Mac that holds it. They are kept with the copy, so it opens whole without the network.
    public var others: [String: String]?

    public static func html(_ html: String) -> PublishedPage { PublishedPage(html: html) }
    public static func file(_ path: String) -> PublishedPage { PublishedPage(file: path) }
    public static func edits(_ edits: [Edit]) -> PublishedPage { PublishedPage(edits: edits) }

    public struct Edit: Codable, Equatable, Sendable {
        public var old: String, new: String
        public init(old: String, new: String) {
            self.old = old
            self.new = new
        }
    }
}

/// How whole Kelp's copy of a page on a service is: everything it uses is on this Mac, or some pictures or styles
/// are missing (the agent uploaded them before Kelp kept them). No copy at all is nil.
public enum ArtifactCopy: String, Codable, CaseIterable, Sendable {
    case full, partial
}

extension Artifacts {
    /// Where a project keeps the files agents upload for their pages (`upload_asset`), by their id on the service.
    public static func blobs(root: String) -> URL { dir(root: root).appendingPathComponent(".blobs") }

    /// What a page's copy uses beside it: the uploaded files (`/_blob/<id>`), and the files it loads from its folder
    /// (`src="…"`, and an `href` to a style sheet), not from the network.
    package static func uses(of text: String) -> (blobs: Set<String>, nearby: [String]) {
        let blobs = Set(text.matches(of: /\/_blob\/([0-9A-Za-z]+)/).map { String($0.output.1) })
        let nearby = text.matches(of: /(src|href)\s*=\s*["']([^"'#?]+)["']/).compactMap { match -> String? in
            let path = String(match.output.2)
            // A value a script fills in (`${…}`, `{{…}}`, `' + x + '`) names no file.
            let filled = ["${", "{{", "+", "<", " "].contains { path.contains($0) }
            guard !filled, !path.contains(":"), !path.hasPrefix("/"), match.output.1 == "src" || path.hasSuffix(".css")
            else { return nil }
            return path
        }
        return (blobs, nearby)
    }

    /// What each copy uses, read again only after the copy is written.
    private static let pageUses = StatMemo<(blobs: Set<String>, nearby: [String])>(limit: 1024)

    /// Returns how whole the copy in `folder` is: nil without a copy, partial while a file it uses isn't on this Mac
    /// (in its folder, or among the project's uploads).
    public static func copyState(folder: URL, root: String) -> ArtifactCopy? {
        let page = folder.appendingPathComponent(pageCopy).path
        guard fileStat(page) != nil else { return nil }
        let uses = pageUses.value(page) { uses(of: small(page).map { String(decoding: $0, as: UTF8.self) } ?? "") }
        let blobs = blobs(root: root)
        let missing =
            uses.blobs.contains { id in
                fileStat(blobs.appendingPathComponent(id).path) == nil
                    && fileStat(folder.appendingPathComponent("_blob/" + id).path) == nil
            } || uses.nearby.contains { fileStat(folder.appendingPathComponent($0).path) == nil }
        return missing ? .partial : .full
    }

    /// Returns the files an `upload_asset` call sent, each with the id the service gave it (`/_blob/<id>`), from its
    /// PostToolUse hook. The answer lists the assets in the order the files were sent. nil for any other call.
    public static func uploaded(hook payload: JSONValue) -> [(path: String, id: String)]? {
        guard payload["hook_event_name"]?.string == "PostToolUse",
            payload["tool_name"]?.string?.hasSuffix("claude-artifacts__upload_asset") == true,
            let files = payload["tool_input"]?["files"]?.array
        else { return nil }
        let answer = payload["tool_response"].map { strings(in: $0).joined(separator: "\n") } ?? ""
        var ids: [String] = []   // in order, each once: an answer may name an asset twice (its link and a snippet)
        for match in answer.matches(of: /\/_blob\/([0-9A-Za-z]+)/) where !ids.contains(String(match.output.1)) {
            ids.append(String(match.output.1))
        }
        let paths = files.compactMap { $0["path"]?.string }
        guard !ids.isEmpty, ids.count == paths.count else { return nil }
        return Array(zip(paths, ids)).map { (path: $0.0, id: $0.1) }
    }

    /// Returns the published page's id on its service, as the tool's answer (or its input) names it: claude.ai's slug.
    public static func serviceId(hook payload: JSONValue) -> String? {
        if let slug = payload["tool_input"]?["slug"]?.string, !slug.isEmpty, !slug.contains("/") { return slug }
        let answer = payload["tool_response"].map { strings(in: $0).joined(separator: "\n") } ?? ""
        return answer.firstMatch(of: /\\?"slug\\?"\s*:\s*\\?"([A-Za-z0-9-]{8,})/).map { String($0.output.1) }
    }

    /// Whether Sync can bring a page whole: a claude.ai artifact (`url`), whose files its tools fetch. A Claude Docs
    /// page (a "doc" with a link) can't be fetched that way, so it isn't counted.
    public static func syncs(url: String?, type: String) -> Bool {
        url?.hasPrefix("https://claude.ai/artifact/") == true && type != Kind.doc.rawValue
    }

    /// The copy of a page on a service that opens without the network, beside `pageCopy` (`artifact.offline`).
    public static let offlineCopy = "offline.html"

    /// Kelp's copy of a page that lives on a service, kept in the artifact's folder.
    public static let pageCopy = "page.html"

    /// Returns the page in a publishing tool's input, and whether it is a Design canvas (with its files under
    /// `project/`).
    package static func sentPage(tool: String, input: JSONValue?) -> (page: PublishedPage?, canvas: Bool) {
        if tool.hasSuffix("__publish_version"), let html = input?["content"]?.string { return (.html(html), false) }
        if tool.hasSuffix("__publish_files") {
            let files = (input?["files"]?.array ?? []).compactMap { f -> (served: String, path: String)? in
                guard let served = f["as"]?.string, let path = f["path"]?.string else { return nil }
                return (served, path)
            }
            let canvas = files.contains { $0.served.hasPrefix("project/") }
            let page =
                files.first { $0.served == "index.html" || $0.served == "project/Main.dc.html" }
                ?? files.first { $0.served.hasSuffix(".html") }
            var sent = page.map { PublishedPage.file($0.path) }
            // Kept where the page loads them from: relative to the page's own folder (a canvas's project/), as the
            // copy sits at the top of the artifact's folder. Files outside that folder aren't the page's.
            let base = page.map { ($0.served as NSString).deletingLastPathComponent } ?? ""
            let prefix = base.isEmpty ? "" : base + "/"
            let others = files.filter { $0.served != page?.served && $0.served.hasPrefix(prefix) }
            if !others.isEmpty {
                sent?.others = Dictionary(others.map { (String($0.served.dropFirst(prefix.count)), $0.path) }) {
                    first, _ in first
                }
            }
            return (sent, canvas)
        }
        if tool.hasSuffix("__edit_version") {
            let path = input?["path"]?.string
            guard path == nil || path == "index.html" || path == "project/Main.dc.html" else { return (nil, false) }
            let edits = (input?["edits"]?.array ?? []).compactMap { e -> PublishedPage.Edit? in
                guard let old = e["old_text"]?.string, let new = e["new_text"]?.string else { return nil }
                return PublishedPage.Edit(old: old, new: new)
            }
            return (edits.isEmpty ? nil : .edits(edits), path?.hasPrefix("project/") == true)
        }
        return (nil, false)
    }
}
