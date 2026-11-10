import Core
import Foundation

/// The daemon is the only writer of `.kelp/artifacts`: new pages (`artifact.new`), links to pages on a service and
/// Kelp's copy of what was sent of them (`artifact.add`), the versions a turn leaves, the copies recovered from a chat's
/// transcript, and the list the panel watches. Core keeps what everyone reads: the records, the paths, the guide.
extension Artifacts {
    /// A folder name from the title, in Latin letters ("План" → "plan"): lowercase words joined by "-", at most 48
    /// characters; "artifact" for none.
    static func slug(_ title: String) -> String {
        let latin =
            title.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false)
            ?? title
        let words = latin.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        var joined = ""
        for word in words where joined.count + word.count + 1 <= 48 { joined += (joined.isEmpty ? "" : "-") + word }
        return joined.isEmpty ? "artifact" : joined
    }

    /// A new page of `kind` in `root`'s artifacts: its folder, its first lines and its record. Returns the page's file.
    static func create(_ kind: Kind, title: String, root: String, session: String?, now: Date = Date()) throws
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

    /// Keeps the link to a page the agent published on its own service, and what it sent of the page (its preview);
    /// nil when it's known already: a later version, which moves its time and, given one, its title and kind.
    static func addNative(
        url: String, title: String, type: String, root: String, session: String?, page: PublishedPage? = nil,
        now: Date = Date()
    ) throws -> URL? {
        if let known = list(root: root).first(where: { $0.record.url == url }) {
            let folder = dir(root: root).appendingPathComponent(known.slug)
            var record = known.record
            record.updated = now
            if title != url { record.title = title }
            if type != "page" { record.type = type }
            try save(record, in: folder)
            try keepPage(page, in: folder)
            return nil
        }
        let folder = try newFolder(title, root: root)
        try save(ArtifactRecord(type: type, title: title, created: now, session: session, url: url), in: folder)
        try keepPage(page, in: folder)
        return folder
    }

    /// The list as the panel shows it, latest change first: a review's answers counted from its file, each file's
    /// last save, a service's page's last publish.
    static func items(root: String) -> [ArtifactItem] {
        list(root: root).map { slug, r in item(slug, r, root: root) }
            .sorted { ($0.modified ?? $0.created) > ($1.modified ?? $1.created) }
    }

    private static func item(_ slug: String, _ r: ArtifactRecord, root: String) -> ArtifactItem {
        let target = target(slug, r, root: root)
        var item = ArtifactItem(
            slug: slug, type: r.type, title: r.title, created: r.created.timeIntervalSince1970, session: r.session,
            url: r.url, target: target)
        guard r.url == nil else {
            item.modified = r.updated?.timeIntervalSince1970
            let copy = dir(root: root).appendingPathComponent(slug).appendingPathComponent(pageCopy).path
            item.preview = fileStat(copy) == nil ? nil : copy
            return item
        }
        item.preview = target
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

    /// A turn of chat `session` ended: each page it made whose file changed since its last version gets a new one, named
    /// `label` (the turn's prompt, on one line). Returns how many were kept.
    @discardableResult
    static func keepVersions(root: String, session: String, label: String, now: Date = Date()) throws -> Int {
        var kept = 0, failed: (any Error)?
        for (slug, record) in list(root: root) where record.session == session && record.file != nil {
            do { kept += try keepVersion(slug, record, root: root, label: label, now: now) ? 1 : 0 } catch {
                failed = failed ?? error
            }   // the others still
        }
        if let failed { throw failed }
        return kept
    }

    private static func keepVersion(_ slug: String, _ record: ArtifactRecord, root: String, label: String, now: Date)
        throws
        -> Bool
    {
        let target = target(slug, record, root: root)
        guard let live = small(target) else { return false }
        var versions = record.versions ?? []
        if let last = versions.last, versionText(target: target, last.n).map({ Data($0.utf8) }) == live { return false }
        let number = (versions.last?.n ?? 0) + 1, folder = URL(fileURLWithPath: target).deletingLastPathComponent()
        let dir = folder.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try live.write(to: URL(fileURLWithPath: versionPath(target: target, number)))
        versions.append(
            ArtifactVersion(n: number, at: now.timeIntervalSince1970, label: oneLine(label, number: number)))
        for old in versions.dropLast(keptVersions) {   // one gone already (by hand) is no reason to stop keeping
            let path = versionPath(target: target, old.n)
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
        var updated = record
        updated.versions = Array(versions.suffix(keptVersions))
        try save(updated, in: folder)
        return true
    }

    static func versionText(target: String, _ number: Int) -> String? {
        small(versionPath(target: target, number)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The prompt's first line, at most 80 characters; "Turn n" for none.
    private static func oneLine(_ prompt: String, number: Int) -> String {
        let line =
            prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "Turn \(number)" }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
    /// Writes the page's copy into its folder: all of it, a file's bytes (HTML only, at most 16 MB), or the edits
    /// applied to the copy there (none there: nothing).
    static func keepPage(_ page: PublishedPage?, in folder: URL) throws {
        let copy = folder.appendingPathComponent(pageCopy)
        if let html = page?.html {
            try Data(html.utf8).write(to: copy, options: .atomic)
        } else if let path = page?.file {
            guard path.hasSuffix(".html"), let data = small(path, limit: 16 << 20) else { return }
            try data.write(to: copy, options: .atomic)
        } else if let edits = page?.edits {
            guard let data = small(copy.path) else { return }
            var text = String(decoding: data, as: UTF8.self)
            for edit in edits {
                if let range = text.range(of: edit.old) { text.replaceSubrange(range, with: edit.new) }
            }
            try Data(text.utf8).write(to: copy, options: .atomic)
        }
    }

    /// Pages on a service published before Kelp kept copies: what the chat that made each sent, replayed in order
    /// from its transcript (`transcript`: the file of a session's conversation), once per page. Each is marked first,
    /// so a run that starts meanwhile (the marks are writes the folder's watch hears) leaves it alone; each transcript
    /// is read once, for all of its chat's pages. Returns how many got a copy.
    @discardableResult
    static func recoverPages(root: String, transcript: (String) -> URL?) -> Int {
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
