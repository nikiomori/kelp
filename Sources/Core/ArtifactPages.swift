import Foundation

/// What a publishing tool sent of the page itself: Kelp keeps a copy of it beside the link, for the panel's preview
/// (Kelp's tabs can't sign in to the service, so they can't show the page there).
public struct PublishedPage: Codable, Equatable, Sendable {
    /// The whole page (`publish_version`).
    public var html: String?
    /// A file on this Mac that holds it (`publish_files`: its index.html, or a canvas's first board).
    public var file: String?
    /// Changes to the last version (`edit_version`), applied to the copy.
    public var edits: [Edit]?

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

extension Artifacts {
    /// Kelp's copy of a page on a service, in the artifact's folder.
    public static let pageCopy = "page.html"

    /// The page in a publishing tool's input, and whether it's a Design canvas (its files under `project/`).
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
}
