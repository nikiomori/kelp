import Foundation

/// What a publishing tool sent of the page itself: Kelp keeps a copy of it beside the link, for the panel's preview
/// (Kelp's tabs can't sign in to the service, so they can't show the page there).
public enum PublishedPage: Equatable, Sendable {
    /// The whole page (`publish_version`).
    case html(String)
    /// A file on this Mac that holds it (`publish_files`: its index.html, or a canvas's first board).
    case file(String)
    /// Changes to the last version (`edit_version`), applied to the copy.
    case edits([Edit])

    public struct Edit: Equatable, Sendable {
        public var old: String, new: String
        public init(old: String, new: String) {
            self.old = old
            self.new = new
        }
    }
}

extension Artifacts {
    /// Kelp's copy of a page on a service, in the artifact's folder.
    public static let pageCopy = "page.html"

    /// The page in a publishing tool's input, and whether it's a Design canvas (its files under `project/`).
    static func sentPage(tool: String, input: JSONValue?) -> (page: PublishedPage?, canvas: Bool) {
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
            return (page.map { .file($0.path) }, canvas)
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

    /// Writes the page's copy into its folder: all of it, a file's bytes (HTML only, at most 16 MB), or the edits
    /// applied to the copy there (none there: nothing).
    static func keepPage(_ page: PublishedPage?, in folder: URL) throws {
        let copy = folder.appendingPathComponent(pageCopy)
        switch page {
        case .html(let html): try Data(html.utf8).write(to: copy, options: .atomic)
        case .file(let path):
            guard path.hasSuffix(".html"), let data = small(path, limit: 16 << 20) else { return }
            try data.write(to: copy, options: .atomic)
        case .edits(let edits):
            guard let data = small(copy.path) else { return }
            var text = String(decoding: data, as: UTF8.self)
            for edit in edits {
                if let range = text.range(of: edit.old) { text.replaceSubrange(range, with: edit.new) }
            }
            try Data(text.utf8).write(to: copy, options: .atomic)
        case nil: return
        }
    }

    /// Pages on a service published before Kelp kept copies: what the chat that made each sent, replayed in order
    /// from its transcript (`transcript`: the file of a session's conversation), once per page. Each is marked first,
    /// so a run that starts meanwhile (the marks are writes the folder's watch hears) leaves it alone; each transcript
    /// is read once, for all of its chat's pages. Returns how many got a copy.
    @discardableResult
    public static func recoverPages(root: String, transcript: (String) -> URL?) -> Int {
        var bySession: [String: [(folder: URL, record: ArtifactRecord)]] = [:]
        for (slug, record) in list(root: root) where record.url != nil && record.recovered != true {
            let folder = dir(root: root).appendingPathComponent(slug)
            guard fileStat(folder.appendingPathComponent(pageCopy).path) == nil, let session = record.session else {
                continue
            }
            var marked = record
            marked.recovered = true
            do { try save(marked, in: folder) } catch { continue }   // unwritable: tried again at the next list
            bySession[session, default: []].append((folder, marked))
        }
        var got = 0
        for (session, pages) in bySession {
            let sent = transcript(session).map { publishes(of: Set(pages.compactMap(\.record.url)), in: $0) } ?? [:]
            for (folder, record) in pages {
                let calls = sent[record.url ?? ""] ?? []
                do {
                    for call in calls { try keepPage(call.page, in: folder) }
                    if calls.contains(where: \.canvas), record.type == "page" {
                        var design = record
                        design.type = Kind.design.rawValue
                        try save(design, in: folder)
                    }
                } catch { continue }
                if fileStat(folder.appendingPathComponent(pageCopy).path) != nil { got += 1 }
            }
        }
        return got
    }

    /// The publishing calls in a transcript whose answers name one of `urls`, in order, by page. Lines are picked by
    /// their bytes; only a publishing call or an answer naming a page is decoded.
    static func publishes(of urls: Set<String>, in file: URL) -> [String: [(page: PublishedPage?, canvas: Bool)]] {
        guard let data = small(file.path, limit: 512 << 20) else { return [:] }
        let marks = (publishers + ["claude.ai/artifact/"]).map { Data($0.utf8) }
        var calls: [String: (tool: String, input: JSONValue?)] = [:]
        var found: [String: [(page: PublishedPage?, canvas: Bool)]] = [:]
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end + 1
            guard marks.contains(where: { line.range(of: $0) != nil }) else { continue }
            let entry: JSONValue
            do { entry = try JSONDecoder().decode(JSONValue.self, from: line) } catch { continue }
            for part in entry["message"]?["content"]?.array ?? [] {
                if part["type"]?.string == "tool_use", let id = part["id"]?.string, let tool = part["name"]?.string,
                    publishers.contains(where: tool.hasSuffix)
                {
                    calls[id] = (tool, part["input"])
                } else if part["type"]?.string == "tool_result", let id = part["tool_use_id"]?.string,
                    let call = calls[id]
                {
                    let text = strings(in: part["content"] ?? .null)
                    for url in urls where text.contains(where: { $0.contains(url) }) {
                        found[url, default: []].append(sentPage(tool: call.tool, input: call.input))
                    }
                }
            }
        }
        return found
    }
}
